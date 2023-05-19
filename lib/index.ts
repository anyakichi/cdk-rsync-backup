import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as s3 from "aws-cdk-lib/aws-s3";
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
  readonly init?: ec2.CloudFormationInit;
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
      props.vpc || cdk.aws_ec2.Vpc.fromLookup(this, "VPC", { isDefault: true });

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
        "Allow SSH Access"
      );
    }

    const instanceType =
      props.instanceType ||
      ec2.InstanceType.of(ec2.InstanceClass.T4G, ec2.InstanceSize.NANO);

    const machineImage = ec2.MachineImage.latestAmazonLinux2023({
      cpuType:
        instanceType.architecture == ec2.InstanceArchitecture.X86_64
          ? ec2.AmazonLinuxCpuType.X86_64
          : ec2.AmazonLinuxCpuType.ARM_64,
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

    const keyPair = new ec2.CfnKeyPair(this, "KeyPair", {
      keyName: "rsync-backup",
    });
    keyPair.applyRemovalPolicy(cdk.RemovalPolicy.DESTROY);

    const initConfig = new ec2.InitConfig([
      ec2.InitCommand.argvCommand([
        "/usr/sbin/grubby",
        "--update-kernel",
        "ALL",
        "--args",
        "selinux=0",
      ]),
      ec2.InitFile.fromString(
        "/etc/environment",
        `MAX_SNAPSHOTS=${maxSnapshots}
         S3_LOGS_BUCKET=${logsBucket.bucketName}`.replace(/^\s+/gm, "")
      ),
      ec2.InitFile.fromAsset(
        "/usr/local/bin/rsync-backup",
        path.join(__dirname, "../assets/rsync-backup.sh"),
        {
          mode: "000755",
        }
      ),
      ec2.InitFile.fromAsset(
        "/srv/rsync-backup/rsyncd.inc",
        path.join(__dirname, "../assets/rsyncd.inc")
      ),
    ]);

    if (props.modules) {
      for (const [i, m] of props.modules.entries()) {
        if (m.size < 0 || !Number.isInteger(m.size)) {
          throw new Error("module size must be a positive integer");
        }

        const device = String.fromCharCode("b".charCodeAt(0) + i);

        initConfig.add(
          ec2.InitFile.fromAsset(
            `/srv/rsync-backup/rsyncd.${m.name}.conf`,
            path.join(__dirname, "../assets/rsyncd.conf")
          )
        );
        initConfig.add(
          ec2.InitCommand.argvCommand([
            "/usr/bin/sed",
            "-i",
            `s/@host@/${m.name}/g`,
            `/srv/rsync-backup/rsyncd.${m.name}.conf`,
          ])
        );
        initConfig.add(
          ec2.InitCommand.shellCommand(
            `echo 'no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="rsync-backup ${m.name} ${m.size} /dev/sd${device}" ${m.sshKey}' >> /root/.ssh/authorized_keys`
          )
        );
      }
    } else {
      initConfig.add(
        ec2.InitFile.fromAsset(
          "/srv/rsync-backup/rsyncd.backup.conf",
          path.join(__dirname, "../assets/rsyncd.conf")
        )
      );
      initConfig.add(
        ec2.InitCommand.argvCommand([
          "/usr/bin/sed",
          "-i",
          `s/@host@/backup/g`,
          `/srv/rsync-backup/rsyncd.backup.conf`,
        ])
      );
      initConfig.add(
        ec2.InitCommand.argvCommand([
          "/usr/bin/sed",
          "-i",
          's|command=".*" |command="rsync-backup backup 100 /dev/sdb" |',
          "/root/.ssh/authorized_keys",
        ])
      );
    }

    const init = (() => {
      if (props.init) {
        props.init.addConfig("rsyncBackup", initConfig);
        return props.init;
      } else {
        return ec2.CloudFormationInit.fromConfig(initConfig);
      }
    })();

    let instanceId = `Instance-${LIB_VERSION.replace(/\.\d+$/, "")}`;
    if (props.instanceVersion) {
      instanceId += `-${props.instanceVersion}`;
    }
    const instance = new ec2.Instance(this, instanceId, {
      keyName: cdk.Token.asString(keyPair.ref),
      vpc,
      securityGroup,
      instanceType,
      machineImage,
      role,
      init,
    });

    instance.addUserData("reboot");

    let eip, eIPAssociation;
    if (props.useEIP) {
      eip = new ec2.CfnEIP(this, "EIP");
      eIPAssociation = new ec2.CfnEIPAssociation(this, "EIPAssociation", {
        eip: eip.ref,
        instanceId: instance.instanceId,
      });
    }

    this.logsBucket = logsBucket;
    this.instance = instance;
  }
}
