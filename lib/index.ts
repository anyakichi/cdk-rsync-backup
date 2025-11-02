import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as s3assets from "aws-cdk-lib/aws-s3-assets";
import { Construct } from "constructs";
import * as path from "path";

import { LIB_VERSION } from "./version";

export interface RsyncBackupModule {
  readonly name: string;
  readonly sshKey: string;
  readonly size: number;
}

export interface RsyncBackupProps {
  readonly modules?: RsyncBackupModule[];
  readonly maxSnapshots?: number;

  readonly instanceVersion?: string;

  readonly keyName?: string;
  readonly vpc?: ec2.IVpc;
  readonly securityGroup?: ec2.ISecurityGroup;
  readonly instanceType?: ec2.InstanceType;
  readonly useEIP?: boolean;

  readonly logsBucket?: s3.IBucket;
  readonly autoDeleteLogs?: boolean;
}

export class RsyncBackup extends Construct {
  public readonly logsBucket: s3.IBucket;
  public readonly instance: ec2.IInstance;

  constructor(scope: Construct, id: string, props: RsyncBackupProps = {}) {
    super(scope, id);

    const maxSnapshots = props.maxSnapshots || 15;
    if (maxSnapshots < 0 || !Number.isInteger(maxSnapshots)) {
      throw new Error("maxSnapshots must be a positive integer");
    }

    const logsBucket =
      props.logsBucket ||
      new s3.Bucket(this, "LogsBucket", {
        removalPolicy: cdk.RemovalPolicy.DESTROY,
        autoDeleteObjects: props.autoDeleteLogs,
      });

    const vpc =
      props.vpc ||
      new cdk.aws_ec2.Vpc(this, "Vpc", {
        ipProtocol: ec2.IpProtocol.DUAL_STACK,
        natGateways: 0,
        subnetConfiguration: [
          {
            name: "Public",
            subnetType: ec2.SubnetType.PUBLIC,
          },
        ],
      });

    let securityGroup: ec2.ISecurityGroup;
    if (props.securityGroup) {
      securityGroup = props.securityGroup;
    } else {
      securityGroup = new ec2.SecurityGroup(this, "SecurityGroup", {
        vpc,
        allowAllOutbound: true,
      });

      securityGroup.addIngressRule(
        ec2.Peer.anyIpv4(),
        ec2.Port.tcp(22),
        "Allow SSH Access",
      );
      securityGroup.addIngressRule(
        ec2.Peer.anyIpv6(),
        ec2.Port.tcp(22),
        "Allow SSH Access",
      );
    }

    const instanceType =
      props.instanceType ||
      ec2.InstanceType.of(ec2.InstanceClass.T4G, ec2.InstanceSize.NANO);

    const arch =
      instanceType.architecture == ec2.InstanceArchitecture.ARM_64
        ? "arm64"
        : "amd64";
    const machineImage = ec2.MachineImage.lookup({
      name: `ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${arch}-server-*`,
      owners: ["099720109477"],
    });

    const policy = new iam.PolicyDocument({
      statements: [
        new iam.PolicyStatement({
          actions: [
            "ec2:DescribeInstances",
            "ec2:DescribeSnapshots",
            "ec2:DescribeVolumes",
            "ec2:DescribeVolumeStatus",
            "ec2:AttachVolume",
            "ec2:DetachVolume",
            "ec2:CreateVolume",
            "ec2:DeleteVolume",
            "ec2:CreateSnapshot",
            "ec2:DeleteSnapshot",
            "ec2:CreateTags",
          ],
          resources: ["*"],
        }),
        new iam.PolicyStatement({
          actions: ["s3:PutObject", "s3:PutObjectAcl"],
          resources: [logsBucket.bucketArn, logsBucket.bucketArn + "/*"],
        }),
      ],
    });

    const role = new iam.Role(this, "InstanceRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      inlinePolicies: {
        rsyncBackup: policy,
      },
    });

    const keyPair = new ec2.KeyPair(this, "KeyPair", {
      keyPairName: "rsync-backup-keypair",
    });
    keyPair.applyRemovalPolicy(cdk.RemovalPolicy.DESTROY);

    let instanceId = `Instance-${LIB_VERSION.replace(/\.\d+$/, "")}`;
    if (props.instanceVersion) {
      instanceId += `-${props.instanceVersion}`;
    }
    const instance = new ec2.Instance(this, instanceId, {
      keyPair,
      vpc,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PUBLIC,
      },
      securityGroup,
      instanceType,
      machineImage,
      role,
    });

    instance.userData.addCommands(
      "apt-get update",
      "apt-get install -y unzip",
      "snap install aws-cli --classic",
    );

    const rsync_backup_sh = new s3assets.Asset(this, "RsyncBackupSh", {
      path: path.join(__dirname, "../assets"),
    });
    rsync_backup_sh.grantRead(instance);
    const asset_path = instance.userData.addS3DownloadCommand({
      bucket: rsync_backup_sh.bucket,
      bucketKey: rsync_backup_sh.s3ObjectKey,
    });

    instance.userData.addCommands(
      `unzip ${asset_path} -d /srv/rsync-backup`,
      `rm ${asset_path}`,
      "mv /srv/rsync-backup/rsync-backup.sh /usr/local/bin/rsync-backup",
      `echo MAX_SNAPSHOTS=${maxSnapshots} >> /etc/environment`,
      `echo S3_LOGS_BUCKET=${logsBucket.bucketName} >> /etc/environment`,
    );

    if (props.modules) {
      for (const [i, m] of props.modules.entries()) {
        if (m.size < 0 || !Number.isInteger(m.size)) {
          throw new Error("module size must be a positive integer");
        }
        const device = String.fromCharCode("f".charCodeAt(0) + i);
        instance.userData.addCommands(
          `cp /srv/rsync-backup/rsyncd.conf /srv/rsync-backup/rsyncd.${m.name}.conf`,
          `sed -i 's/@host@/${m.name}/g' /srv/rsync-backup/rsyncd.${m.name}.conf`,
          `echo 'no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="rsync-backup ${m.name} ${m.size} /dev/sd${device}" ${m.sshKey}' >> /root/.ssh/authorized_keys`,
        );
      }
    } else {
      instance.userData.addCommands(
        "cp /srv/rsync-backup/rsyncd.conf /srv/rsync-backup/rsyncd.backup.conf",
        "sed -i 's/@host@/backup/g' /srv/rsync-backup/rsyncd.backup.conf",
        `sed -i 's|command=".*" |command="rsync-backup backup 100 /dev/sdf" |' /root/.ssh/authorized_keys`,
      );
    }
    instance.userData.addCommands("rm /srv/rsync-backup/rsyncd.conf");

    let eip: ec2.CfnEIP | undefined;
    let eIPAssociation: ec2.CfnEIPAssociation | undefined;
    if (props.useEIP) {
      eip = new ec2.CfnEIP(this, "EIP", {
        domain: "vpc",
      });
      eIPAssociation = new ec2.CfnEIPAssociation(this, "EIPAssociation", {
        allocationId: eip.attrAllocationId,
        instanceId: instance.instanceId,
      });
    }

    this.logsBucket = logsBucket;
    this.instance = instance;
  }
}
