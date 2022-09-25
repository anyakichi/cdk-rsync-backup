# CDK Rsync Backup

AWS CDK L3 construct for cloud backup system with rsync.

Create a full system backup of an on-premise server as EBS snapshots.
When you send files with rsync, the system will

- Create an EBS volume (from snapshot if exists)
- Attach and mount the volume to the EC2 instance
- Receive rsync data
- Unmount and detach the volume
- Create a EBS snapshot from the volume
- Delete the volume
- Upload log file into S3 bucket

## Installation

```
$ npm install @anyakichi/cdk-rsync-backup
```

## Usage

### Backup

```typescript
import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import { RsyncBackup } from "@anyakichi/cdk-rsync-backup";

export class CdkDemoStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // Create `hostname` rsync module with 100 GiB EBS.
    // SSH public key is required per module.
    const rsyncBackup = new RsyncBackup(this, "RsyncBackup", {
      modules: [
        {
          name: "hostname",
          sshKey: "ssh-rsa AAAAB3Nza...",
          size: 100,
        },
      ],
    });
  }
}
```

If no EBS snapshot for `hostname` does not exist, a new EBS volume is
created on rsync execution with specified `size`.

If an EBS snapshot exist, a new EBS volume is created from the latest
EBS snapshot. The volume size is depends on the snapshot and `size`
parameter is ignored.

When you create a new backup, simply execute rsync.

```
# rsync -azAXHS -e 'ssh -i id_rsa' --delete --numeric-ids \
    --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"}
    / root@ec2-XXX-XXX-XXX-XXX.compute-1.amazonaws.com::hostname/
```

You can get the host SSH private key to login your instance from AWS
System Manager Parameter Sotre.

```
$ aws ssm get-parameter \
    --name /ec2/keypair/$(aws ec2 describe-key-pairs \
      --key-names rsync-backup --query "KeyPairs[].KeyPairId" --output text) \
    --with-decryption --query Parameter.Value --output text
```

### Restore

Create a new EC2 instance and attach a volume created from a required
snapshot, then copy the backup data.

Reading backup data from the backup instance is disabled by default.

## Recommended workflow

Backup data transfer on Internet is not always reliable. Two-way backup
is recommended for reliability.

- Take a snapshot on local machine. rsnapshot with LVM snapshot is easy
  and convenient. This should be finished in predictable time.

- Send a local backup to EC2 instance.

First level backups can be used for recovery from operation mistakes.
You can easily copy the files from local backups.

Second level backups are for disaster recovery. Its recovery cost is
relatively high.
