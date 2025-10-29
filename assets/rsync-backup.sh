#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

export AWS_DEFAULT_REGION
AWS_DEFAULT_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

main() {
    local host="$1"
    local size="$2"
    local device="$3"
    local name="backup-$1"
    local mnt="/srv/rsync-backup/mnt/$host"
    local logfile="/srv/rsync-backup/rsync-backup.$host.log"
    local args dev logfile_gz s3base snapshot_id timestamp volume_id
    local -a snapshot_ids

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

        # Get the latest snapshot ID.
        snapshot_id=$(aws ec2 describe-snapshots --owner-ids self \
            --filter "Name=tag:Name,Values=$name" \
            --query "reverse(sort_by(Snapshots,&StartTime))[0].SnapshotId" \
            --output text)

        args=()
        if [[ $snapshot_id != None ]]; then
            args+=(--snapshot-id "$snapshot_id")
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
    fi

    mkdir -p "$mnt/$host"

    df -h "$dev" >>"$logfile"

    rsync --server --daemon --config="/srv/rsync-backup/rsyncd.$host.conf" .

    df -h "$dev" >>"$logfile"

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

        if ((MAX_SNAPSHOTS > 0)); then
            read -r -a snapshot_ids <<<"$(aws ec2 describe-snapshots \
                --owner-ids self \
                --filter "Name=tag:Name,Values=$name" \
                --query "reverse(sort_by(Snapshots,&StartTime))[].SnapshotId" \
                --output text)"
            for ((i = MAX_SNAPSHOTS; i < ${#snapshot_ids}; i++)); do
                aws ec2 delete-snapshot --snapshot-id "${snapshot_ids[$i]}"
            done
        fi
    ) &>/dev/null &
    disown
}

main "$@"
