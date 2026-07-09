#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

export AWS_DEFAULT_REGION
AWS_DEFAULT_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

prune_snapshots() {
    local name="$1"
    local i
    local -a snapshot_ids

    if ((MAX_SNAPSHOTS > 0)); then
        read -r -a snapshot_ids <<<"$(aws ec2 describe-snapshots \
            --owner-ids self \
            --filter "Name=tag:Name,Values=$name" \
            --query "reverse(sort_by(Snapshots,&StartTime))[].SnapshotId" \
            --output text)"
        for ((i = MAX_SNAPSHOTS; i < ${#snapshot_ids[@]}; i++)); do
            aws ec2 delete-snapshot --snapshot-id "${snapshot_ids[$i]}"
        done
    fi
}

main() {
    local host="$1"
    local size="$2"
    local device="$3"
    local name="backup-$1"
    local mnt="/srv/rsync-backup/mnt/$host"
    local logfile="/srv/rsync-backup/rsync-backup.$host.log"
    local args dev logfile_gz migrate new_dev new_device new_mnt \
        new_volume_id s3base snapshot_id snapshot_size stale_volume_ids \
        timestamp used v volume_id volume_size

    # Serialize runs per host. The lock is inherited by the disowned
    # background jobs, so it is held until the snapshot cleanup or the
    # shrink migration is finished.
    exec 9>"/srv/rsync-backup/rsync-backup.$host.lock"
    if ! flock -n 9; then
        echo "backup or migration for $host is in progress" >&2
        exit 1
    fi

    timestamp="$(date -u "+%Y%m%dT%H%MZ")"
    s3base=s3://$S3_LOGS_BUCKET/RsyncBackupLogs/$(date -u "+%Y/%m/%d")/
    logfile_gz="/srv/rsync-backup/RsyncBackup-$host-$timestamp.log.gz"

    volume_id=$(aws ec2 describe-volumes \
        --filter "Name=tag:Name,Values=$name" \
        --query "Volumes[].VolumeId" --output text)

    # If volume is already mounted, previous rsync should be failed. Use
    # the mounted volume in this case.
    # If volume is not mounted, create and attach a volume and mount it.
    if ! mountpoint -q "$mnt"; then
        if [[ -n $volume_id ]]; then
            # Data volume already exists.
            echo backup volume already exists
            exit 1
        fi

        # Get the latest snapshot ID and its volume size.
        read -r snapshot_id snapshot_size <<<"$(aws ec2 describe-snapshots \
            --owner-ids self \
            --filter "Name=tag:Name,Values=$name" \
            --query "reverse(sort_by(Snapshots,&StartTime))[0].[SnapshotId,VolumeSize]" \
            --output text)"

        args=()
        if [[ $snapshot_id != None ]]; then
            args+=(--snapshot-id "$snapshot_id")
            if ((size > snapshot_size)); then
                # Grow the volume. The filesystem is expanded with
                # resize2fs after mount.
                args+=(--size "$size")
            elif ((size < snapshot_size)); then
                # The shrink migration reads the whole volume, which is
                # painfully slow against lazily-loaded snapshot blocks.
                # Pay for provisioned-rate initialization instead.
                args+=(--volume-initialization-rate 100)
            fi
        else
            args+=(--size "$size")
        fi
        volume_id=$(aws ec2 create-volume --availability-zone "$INSTANCE_AZ" \
            --encrypted --volume-type gp3 \
            --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$name},{Key=rsync-backup,Value=''}]" \
            --query VolumeId --output text "${args[@]}")

        aws ec2 wait volume-available --volume-ids "$volume_id"
        aws ec2 attach-volume --volume-id "$volume_id" \
            --instance-id "$INSTANCE_ID" --device "$device" &>/dev/null

        if [[ -e /dev/disk/by-id ]]; then
            dev="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${volume_id/-/}_1"
        else
            dev="${device/sd/xvd}"
        fi

        while true; do
            if [[ -e $dev ]]; then
                break
            fi
            sleep 1
        done

        mkdir -p "$mnt"
        if [[ $snapshot_id == None ]]; then
            mkfs.ext4 -q "$dev"
        fi
        mount "$dev" "$mnt"
    else
        dev=$(findmnt -no SOURCE "$mnt")
    fi

    # Expand the filesystem to the volume size. This is a no-op unless
    # the volume was created larger than the snapshot.
    resize2fs "$dev" >>"$logfile" 2>&1

    volume_size=$(aws ec2 describe-volumes --volume-ids "$volume_id" \
        --query "Volumes[0].Size" --output text)

    mkdir -p "$mnt/$host"

    df -h "$dev" >>"$logfile"

    rsync --server --daemon --config="/srv/rsync-backup/rsyncd.$host.conf" .

    df -h "$dev" >>"$logfile"

    # If the requested size is smaller than the current volume, migrate
    # the data to a new smaller volume after the transfer so that the
    # client does not have to wait.
    migrate=""
    if ((volume_size > size)); then
        used=$(df -BG --output=used "$mnt" | tail -n 1 | tr -dc '0-9')
        if ((used * 100 < size * 90)); then
            migrate=1
        else
            echo "data (${used}G used) does not fit into ${size}G;" \
                "keeping ${volume_size}G volume" >>"$logfile"
        fi
    fi

    if [[ -z $migrate ]]; then
        umount "$mnt"

        aws ec2 detach-volume --volume-id "$volume_id" &>/dev/null

        snapshot_id=$(aws ec2 create-snapshot --volume-id "$volume_id" \
            --description "$name-$timestamp" \
            --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$name},{Key=rsync-backup,Value=''}]" \
            --query SnapshotId --output text)

        gzip -c "$logfile" >"$logfile_gz"

        aws s3 cp "$logfile_gz" "$s3base"

        rm -f "$logfile" "$logfile_gz"

        (
            while true; do
                aws ec2 wait snapshot-completed --snapshot-ids "$snapshot_id" &&
                    break
            done
            aws ec2 wait volume-available --volume-ids "$volume_id"
            aws ec2 delete-volume --volume-id "$volume_id"

            prune_snapshots "$name"
        ) &>/dev/null &
        disown
        return
    fi

    new_mnt="$mnt.new"
    # Attach in the q-z range so we never collide with module devices
    # (f-p). The real device node is resolved by volume ID anyway.
    new_device="${device%?}$(tr 'f-p' 'q-z' <<<"${device: -1}")"

    (
        # Clean up a stale volume from a previously failed migration.
        umount "$new_mnt" 2>/dev/null || true
        stale_volume_ids=$(aws ec2 describe-volumes \
            --filter "Name=tag:Name,Values=$name-migrating" \
            --query "Volumes[].VolumeId" --output text)
        for v in $stale_volume_ids; do
            aws ec2 detach-volume --volume-id "$v" &>/dev/null || true
            aws ec2 wait volume-available --volume-ids "$v"
            aws ec2 delete-volume --volume-id "$v"
        done

        new_volume_id=$(aws ec2 create-volume \
            --availability-zone "$INSTANCE_AZ" \
            --encrypted --volume-type gp3 --size "$size" \
            --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$name-migrating},{Key=rsync-backup,Value=''}]" \
            --query VolumeId --output text)

        aws ec2 wait volume-available --volume-ids "$new_volume_id"
        aws ec2 attach-volume --volume-id "$new_volume_id" \
            --instance-id "$INSTANCE_ID" --device "$new_device" &>/dev/null

        if [[ -e /dev/disk/by-id ]]; then
            new_dev="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${new_volume_id/-/}_1"
        else
            new_dev="${new_device/sd/xvd}"
        fi

        while true; do
            if [[ -e $new_dev ]]; then
                break
            fi
            sleep 1
        done

        mkfs.ext4 -q "$new_dev"
        mkdir -p "$new_mnt"
        mount "$new_dev" "$new_mnt"

        rsync -aAXHS --numeric-ids --exclude=/lost+found \
            "$mnt/" "$new_mnt/" >>"$logfile" 2>&1

        df -h "$new_dev" >>"$logfile"

        umount "$new_mnt" "$mnt"

        aws ec2 detach-volume --volume-id "$volume_id" &>/dev/null
        aws ec2 detach-volume --volume-id "$new_volume_id" &>/dev/null

        aws ec2 create-tags --resources "$new_volume_id" \
            --tags "Key=Name,Value=$name"

        snapshot_id=$(aws ec2 create-snapshot --volume-id "$new_volume_id" \
            --description "$name-$timestamp" \
            --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$name},{Key=rsync-backup,Value=''}]" \
            --query SnapshotId --output text)

        gzip -c "$logfile" >"$logfile_gz"

        aws s3 cp "$logfile_gz" "$s3base"

        rm -f "$logfile" "$logfile_gz"

        while true; do
            aws ec2 wait snapshot-completed --snapshot-ids "$snapshot_id" &&
                break
        done
        aws ec2 wait volume-available --volume-ids "$volume_id" "$new_volume_id"
        aws ec2 delete-volume --volume-id "$volume_id"
        aws ec2 delete-volume --volume-id "$new_volume_id"

        prune_snapshots "$name"
    ) &>/dev/null &
    disown
}

main "$@"
