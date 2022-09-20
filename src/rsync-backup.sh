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
    local name="backup-$1"
    local device snapshot_id volume_id

    volume_id=$(aws ec2 describe-volumes \
        --filter "Name=tag:Name,Values=$name" \
        --query "Volumes[].VolumeId" --output text)

    if [ -n "$volume_id" ]; then
        # Exit if backup volume already exists.  Another rsync might run.
        echo backup volume already exists
        exit 1
    fi

    # Get the latest snapshot ID.
    snapshot_id=$(aws ec2 describe-snapshots --owner-ids self \
        --filter "Name=tag:Name,Values=$name" \
        --query "reverse(sort_by(Snapshots,&StartTime))[0].SnapshotId" \
        --output text)

    if [[ $snapshot_id == None ]]; then
        echo no snapshots found
        exit 1
    fi

    volume_id=$(aws ec2 create-volume --availability-zone "$INSTANCE_AZ" \
        --volume-type gp3 \
        --snapshot-id "$snapshot_id" \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$name},{Key=backup,Value=''},{Key=$host,Value=''}]" \
        --query VolumeId --output text)

    aws ec2 wait volume-available --volume-ids "$volume_id"

    for i in b c d e f g; do
        if [[ ! -e "/dev/sd$i" ]]; then
            device="/dev/sd$i"
            break
        fi
    done

    aws ec2 attach-volume --volume-id "$volume_id" --instance-id "$INSTANCE_ID" --device "/dev/sd$i" &>/dev/null

    while true; do
        if [[ -e $device ]]; then
            break
        fi
        sleep 1
    done

    mkdir -p "/srv/backups/$host"
    mount "$device" "/srv/backups/$host"
    mkdir -p "/srv/backups/$host/$host"

    cat <<EOF >"/tmp/rsyncd.$host.conf"
uid = root
gid = root
log file = /var/log/rsyncd.$host.log
read only = no
write only = yes

[backup]
    path = /srv/backups/$host/$host
EOF

    rsync --server --daemon --config="/tmp/rsyncd.$host.conf" .

    umount "/srv/backups/$host"

    aws ec2 detach-volume --volume-id "$volume_id" &>/dev/null

    snapshot_id=$(aws ec2 create-snapshot --volume-id "$volume_id" \
        --description "$name-$(date -Iseconds)" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$name},{Key=backup,Value=''},{Key=$host,Value=''}]" \
        --query SnapshotId --output text)

    aws ec2 wait snapshot-completed --snapshot-ids "$snapshot_id"
    aws ec2 wait volume-available --volume-ids "$volume_id"
    aws ec2 delete-volume --volume-id "$volume_id"
}

main "$@"
