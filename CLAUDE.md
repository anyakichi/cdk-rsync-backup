# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `npm run build` — compile TypeScript (`lib/*.ts` → `lib/*.js` + `.d.ts`). `prebuild` regenerates `lib/version.ts` from `package.json` version.
- `npm test` — run Jest tests (`ts-jest`, matches `test/**/*.test.ts`).
- `npm run watch` — `tsc -w` for incremental compilation.
- `npm run format` — run `sort-package-json` + Prettier over `package.json` and `lib`. Prettier sorts imports (`prettier.config.js`).

Compiled JS/`.d.ts` output is committed alongside the sources in `lib/` (this is the published npm package, `main: lib/index.js`). Run `npm run build` after editing `lib/index.ts` so the shipped `.js` stays in sync.

There is no lint step and no CDK app here — this is a library (L3 construct) consumed by other CDK stacks. Publishing is automated: `.github/workflows/publish.yml` runs `npm publish` (npm trusted publishing / OIDC) on GitHub release creation.

## Architecture

This package exports one L3 construct, `RsyncBackup` (`lib/index.ts`). The design splits responsibilities between **synth time** (TypeScript, generates CloudFormation) and **backup runtime** (bash on the EC2 instance).

### Synth time — `lib/index.ts`

The constructor provisions: an S3 logs bucket, a dual-stack VPC (public subnet, no NAT), a security group (SSH open to the world), an IAM role granting the EC2/S3/SSM actions the backup script needs, an EC2 key pair, and a single long-lived EC2 instance (Ubuntu 24.04, `t4g.nano` default). Most props have sensible defaults and can be overridden (`vpc`, `securityGroup`, `instanceType`, `logsBucket`, etc.).

Nearly all behavior is wired through **EC2 UserData** built up incrementally in the constructor:
- Installs `aws-cli`, downloads the `assets/` directory (packaged as an `s3assets.Asset`, unzipped to `/srv/rsync-backup`), installs `rsync-backup.sh` as `/usr/local/bin/rsync-backup`.
- Writes `MAX_SNAPSHOTS` and `S3_LOGS_BUCKET` into `/etc/environment`.
- For each `RsyncBackupModule`, renders a per-module `rsyncd.<name>.conf` (via `sed` on `@host@`) and appends a **forced-command** line to `/root/.ssh/authorized_keys`. That forced command is what pins an incoming SSH/rsync session to `rsync-backup <name> <size> /dev/sd<X>` — the client-supplied rsync command is ignored. Device letters are assigned sequentially from `f` per module index.
- With no `modules`, a single `backup` module is configured as a fallback.

Two notable optional flags:
- `swapSize` — appends `fallocate`/`mkswap`/`swapon` + `/etc/fstab` commands (helps small instance types survive heavy rsync).
- `useEIP` — allocates an EIP **and** injects a UserData block that persists SSH host keys to SSM Parameter Store (`/ec2/hostkeys/rsync-backup/*`), so a re-created fixed-IP instance keeps the same host keys.

The instance's CDK logical ID embeds the library version (`Instance-<major.minor>`, optionally `-<instanceVersion>`); bumping it forces instance replacement.

### Runtime — `assets/rsync-backup.sh`

This is the actual backup engine, invoked once per rsync connection via the authorized_keys forced command. Per run it: finds/creates an encrypted gp3 EBS volume (from the latest matching snapshot if one exists, else fresh + `mkfs.ext4`), attaches and mounts it, runs `rsync --server --daemon` with the module's config to receive data, unmounts/detaches, creates a snapshot tagged `Name=backup-<host>` + `rsync-backup`, uploads a gzipped log to S3, then **backgrounds** (via `disown`) the snapshot-wait → volume-delete → old-snapshot pruning (keeping `MAX_SNAPSHOTS`, default 15). Size changes are handled at runtime: growing creates the volume larger from the snapshot + `resize2fs`; shrinking receives the transfer on the old-size volume, then migrates data to a fresh smaller volume in the disowned background block (interim tag `Name=backup-<host>-migrating`, module device letter mapped f–p→q–z) and snapshots the new volume. Runs are serialized per host with `flock` on `/srv/rsync-backup/rsync-backup.<host>.lock`, held by the background block until cleanup/migration completes. Because the background block dies with the instance (e.g. instance replacement on deploy), each run first reclaims stale detached volumes: `-migrating` copies unconditionally, `backup-<host>` volumes only when a completed snapshot newer than the volume exists (otherwise the run still aborts with "backup volume already exists" to preserve unsnapshotted data). Volumes and snapshots are correlated by the `Name=backup-<host>` tag. `assets/rsyncd.conf` + `rsyncd.inc` are the rsyncd templates (`@host@` is substituted at synth time).

### Tests

`test/cdk-rsync-backup.test.ts` is currently a commented-out placeholder — there is no meaningful test coverage yet. New tests would use `aws-cdk-lib/assertions` `Template.fromStack` against a stack containing `RsyncBackup`.
