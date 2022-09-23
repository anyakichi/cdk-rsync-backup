#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

export AWS_DEFAULT_REGION
AWS_DEFAULT_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)

main() {
    local host="$1"
    local size="$2"
    local device="$3"
    local name="backup-$1"
    local mnt="/srv/rsync-backup/mnt/$host"
    local args rsync_status s3base snapshot_id timestamp volume_id

    timestamp="$(date -u "+%Y%m%dT%H%MZ")"
    s3base=s3://$S3_LOGS_BUCKET/RsyncBackupLogs/$(date -u "+%Y/%m/%d")/

    volume_id=$(aws ec2 describe-volumes \
        --filter "Name=tag:Name,Values=$name" \
        --query "Volumes[].VolumeId" --output text)
    if [ -n "$volume_id" ]; then
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
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$name}]" \
        --query VolumeId --output text "${args[@]}")

    aws ec2 wait volume-available --volume-ids "$volume_id"
    aws ec2 attach-volume --volume-id "$volume_id" \
        --instance-id "$INSTANCE_ID" --device "$device" &>/dev/null

    while true; do
        if [[ -e $device ]]; then
            break
        fi
        sleep 1
    done

    mkdir -p "$mnt"
    if [[ $snapshot_id == None ]]; then
        mkfs.ext4 -q "$device"
    fi
    mount "$device" "$mnt"

    mkdir -p "$mnt/$host"

    rsync --server --daemon --config="/srv/rsync-backup/rsyncd.$host.conf" . && :
    rsync_status=$?

    umount "$mnt"

    aws ec2 detach-volume --volume-id "$volume_id" &>/dev/null

    if [[ $rsync_status == 0 ]]; then
        snapshot_id=$(aws ec2 create-snapshot --volume-id "$volume_id" \
            --description "$name-$timestamp" \
            --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$name}]" \
            --query SnapshotId --output text)

        logfile_gz="/srv/rsync-backup/RsyncBackup-$host-$timestamp.log.gz"
        gzip -c "/srv/rsync-backup/rsync-backup.$host.log" >"$logfile_gz"

        aws s3 cp "$logfile_gz" "$s3base"

        rm -f "/srv/rsync-backup/rsync-backup.$host.log" "$logfile_gz"

        aws ec2 wait snapshot-completed --snapshot-ids "$snapshot_id"
    fi

    aws ec2 wait volume-available --volume-ids "$volume_id"
    aws ec2 delete-volume --volume-id "$volume_id"
}

main "$@"
