# eye-ai-compute-platform

### AWS DLAMI + JupyterHub for GPU-enabled collaborative compute workloads.

---
This repository provides a host-native JupyterHub deployment for AWS DLAMI instances with:

* persistent `/home` and `/data` on EBS
* ext4 user quotas on `/home`
* systemd-managed services
* per-release, revertable JupyterHub installs
* Globus authentication with automatic UNIX user provisioning

The primary goal is **easy DLAMI upgrades** with **zero data loss**, **explicit updates**, and **minimal moving parts**.

---

## Design Overview

### Core principles

1. **Persistent data lives on EBS**

   * `/home` (user homes + JupyterHub state)
   * `/data` (shared project data)

2. **Root filesystem is disposable**

   * Anything written to `/usr` or `/etc` must be reproducible via one command

3. **Deployments are atomic and revertable**

   * Each release is a full copy of the repo
   * Python dependencies live in a per-release virtualenv
   * `bin/activate-release.sh` builds before it flips and verifies after, and
     reverts both the release symlink and the database if the hub does not come
     back. Deploys and automatic updates use that one implementation.
   * Shared state under `state/` is the exception -- see [Rollback](#rollback)

4. **Bootstrap and updates are explicit**

   * Clean systems bootstrap strictly
   * Existing systems do not mutate on restart
   * Updates run only via a timer or manual invocation

---

## Directory Layout

### Persistent (EBS-backed)

```
/home
├── <users>/                     # user home directories
└── jupyterhub/
    ├── releases/
    │   ├── 20250101T120000Z/    # full repo copy
    │   ├── 20250110T083000Z/
    │   └── ...
    ├── current -> releases/<ts>
    ├── previous -> releases/<ts>
    └── state/
        ├── jupyterhub.sqlite
        ├── jupyterhub_cookie_secret
        ├── .last-db-backup        # path of the most recent pre-migration copy
        ├── .release.lock          # serializes deploys against weekly updates
        ├── backups/               # timestamped db copies + pip freezes
        ├── pid/
        ├── logs/
        └── user-venv/
```

State is shared across releases, so nothing under `state/` is reverted by a
release rollback. See [Rollback](#rollback) for the database and user-venv.

### Root filesystem (reproducible)

```
/usr/local/sbin/
├── mount-ebs-volumes.sh
├── enable-home-quotas.sh
├── jupyterhub-notify-failure.sh
└── system-status                 # report and acknowledge

/etc/update-motd.d/
└── 99-system-status -> /usr/local/sbin/system-status

/etc/systemd/system/
├── mount-ebs-volumes.service
├── enable-home-quotas.service
├── jupyterhub.service
├── jupyterhub-update.service
├── jupyterhub-update.timer
└── jupyterhub-failure-notify@.service
```

The failure handler lives in `/usr/local/sbin` rather than inside a release, so
it still works when the release is what broke.

All rootfs files are installed from this repo via installer scripts.

---

## Boot Order (systemd)

```
local-fs.target             # fstab mounts /home, /data, /opt/dlami/nvme by UUID
    ↓
mount-ebs-volumes.service   # first-boot bootstrap; a no-op once fstab is set
    ↓
enable-home-quotas.service
    ↓
jupyterhub.service
```

JupyterHub **will not start** unless:

* `/home` is mounted
* quotas are enabled
* a release exists at `/home/jupyterhub/current`

This is enforced via `Requires=`, `After=`, and `ConditionPath*`.

---

## Services

### 1. `mount-ebs-volumes.service`

**Purpose**

* Bootstrap `/home` and `/data` on first boot: format if requested, add
  `/etc/fstab` entries by UUID, mount
* Set shared `/data` group permissions
* Optionally configure NVMe swap

**On an already-configured host this unit is a fast no-op.** Every mount it
manages is in `/etc/fstab` by UUID and is mounted by systemd before this unit
runs. If the mounts are in place, it does nothing.

**Ordering**

It runs `After=local-fs.target`, deliberately. The script decides what to do by
checking whether `/home` is already a mountpoint, so running before the fstab
mounts would race the very thing it inspects. Ordering it before
`local-fs.target` also puts it in front of every other unit, including sshd.

Note that `Wants=` is a dependency, not an ordering. Removing `Before=` without
adding `After=` leaves the race in place and only stops it blocking the boot.

`TimeoutStartSec=300` bounds it, because `Type=oneshot` otherwise defaults to
infinity and a hang has no recovery path except the serial console.

**Safety flags**

Two operations are destructive or slow enough that they must never fire during
an ordinary boot. Both are off by default and must be set explicitly:

| Flag | Guards |
|---|---|
| `ALLOW_MKFS=1` | `mkfs.ext4 -F` on a device with no filesystem. Kernel names such as `/dev/nvme1n1` are **not** stable across boots -- this host has four NVMe controllers -- so an unattended format can hit the wrong disk. |
| `ALLOW_HOME_MIGRATION=1` | The one-time rootfs `/home` -> EBS copy. Also requires an absent sentinel at `/var/lib/eye-ai-compute/home-migrated`, `/home` not already a mountpoint, and the target device not mounted anywhere else. |

Run either by hand, once, after confirming the device. From a root shell -- a
default sudoers policy rejects setting variables on a `sudo` command line:

```bash
ALLOW_MKFS=1 /usr/local/sbin/mount-ebs-volumes.sh
```

**Script**

* `/usr/local/sbin/mount-ebs-volumes.sh`

**Source of truth**

* `bin/mount-ebs-volumes.sh` (in repo)

---

### 2. `enable-home-quotas.service`

**Purpose**

* Enable ext4 user quotas on `/home`
* Run `quotacheck`
* Turn quotas on
* Apply default quotas to existing users

**Script**

* `/usr/local/sbin/enable-home-quotas.sh`

**Defaults**

* Soft: 50 GiB
* Hard: 60 GiB
* Configurable via environment variables in `etc/quotas.env`. NOTE: Values are in KiB (`GiB*1024*1024`). Example:
    ```dotenv
    # 80/100 GiB in KiB:
    QUOTA_SOFT_KIB=83886080
    QUOTA_HARD_KIB=104857600

    # Optional:
    # APPLY_EXISTING_USERS=0
    # HOME_QUOTA_FS=/home
    ```

---

### 3. `jupyterhub.service`

**Purpose**

* Run JupyterHub itself

**Key characteristics**

* Runs on host
* Uses per-release venv
* Uses shared state directory
* Retries startup on transient failure (bounded)

**Bootstrap behavior**

* `ExecStartPre` runs `bin/bootstrap-jupyterhub.sh` in **strict mode**
* On a clean system:
  * creates venvs
  * installs required Python packages
* On an existing system:
  * performs validation only
  * **does not upgrade packages**

---

### 4. `jupyterhub-update.service` + `.timer`

**Purpose**

* Perform **explicit** upgrades of Python dependencies, within the version
  bounds pinned in the release

**Behavior**

Runs `bin/update-jupyterhub-release.sh`, which stages a new timestamped release
from the current release's source tree, builds a fresh venv from
`etc/requirements-hub.txt`, and discards it again if `pip freeze` shows no
package change. If packages did change, it hands the staged release to
`bin/activate-release.sh`.

### `activate-release.sh` owns everything dangerous

Both the weekly update and `install-jupyterhub-service.sh` stage a directory and
then call it, so a deploy and an automatic update follow identical code paths.
Its rule:

> Build before you flip, verify after you flip, and never exit without doing one
> or the other.

In order:

1. Take the release lock, so a deploy and an update can never interleave
2. Build the venv while the old release is still serving -- a failure here costs
   nothing, because the flip has not happened
3. Back up and migrate the database, *only* now, having committed to the flip.
   Migration is not reversible, so it must never run on a path that might
   discard the release
4. Flip `previous` and `current`, restart, and poll the hub's health endpoint
5. On failure, revert the symlink, restore the pre-migration database, and
   restart -- driven by an `EXIT` trap, so a `SIGTERM` from `TimeoutStartSec`
   cannot abandon the system half-changed

Contention is deterministic rather than queued. The update probes the lock
before doing any work and defers if a deploy is running; activation itself uses
a non-blocking lock and exits 75 (`EX_TEMPFAIL`), which the update treats as
"try again next week". A deploy waits up to `JH_LOCK_WAIT` seconds and then
fails loudly rather than proceeding.

`JH_ROLLBACK_ON_FAILURE=0` declines to revert but still verifies and still exits
non-zero, leaving a warning naming the release that needs reverting by hand.

The health check polls the hub's endpoint rather than just `systemctl is-active`,
because a hub can keep its process alive without being able to answer requests.
The URL is **derived from the release's own `jupyterhub_config.py`** --
`c.JupyterHub.bind_url` plus `c.JupyterHub.base_url` plus `hub/health`, giving
`http://127.0.0.1:8000/hub/health` on the current config -- so it cannot drift
from the config the way a hardcoded default would.

That is deliberately the proxy address, not the Hub's internal API port (8081 by
default). Checking the internal port would report success with
`configurable-http-proxy` dead, when nothing is actually reachable.

The parser reads string literals only. A config that computes `bind_url` or
`base_url` from the environment needs `JH_HEALTH_URL` set explicitly; the script
warns and degrades to `systemctl is-active` if it cannot parse one.

Note the limit: no automated check catches a broken authenticator flow, so
validate a real Globus sign-in by hand after any upgrade crossing a major version.

It does **not** upgrade packages inside the running release. That distinction
matters: an update that mutates `current/venv` in place makes the deployed
release differ from what was deployed, and a symlink-flip rollback can no longer
restore the previous package set.

The hub is restarted, so it is briefly unavailable and running single-user
servers are stopped.

**Version pinning**

Package versions are bounded in `etc/requirements-hub.txt` and
`etc/requirements-user.txt`, which ship with the release. Raising a major bound
is a reviewed change: edit the requirements file, deploy with
`install-jupyterhub-service.sh`, and validate a real login and spawn.

An unbounded upgrade lets a weekly run cross a major version unattended. That
matters most for the database: JupyterHub changes its schema across releases and
refuses to start until `jupyterhub upgrade-db` has run, which `activate-release.sh`
handles as part of every activation.

**Manual invocation**

```bash
systemctl start jupyterhub-update
journalctl -u jupyterhub-update.service -f
```

Note that the upgrade log lives in `jupyterhub-update.service`, not in
`jupyterhub.service`. When a restart follows an update, the reason is in the
update unit's journal.

---

### 5. `jupyterhub-failure-notify@.service`

**Purpose**

* Report a failed unit, so automatic recovery is not also silent recovery

`jupyterhub.service`, `jupyterhub-update.service` and `mount-ebs-volumes.service`
all declare `OnFailure=jupyterhub-failure-notify@%n.service`. The template runs
`/usr/local/sbin/jupyterhub-notify-failure.sh` with the failing unit's status and
its last 50 journal lines.

This exists because the automation recovers on its own. A failed weekly update
rolls back to the previous release and restores the pre-migration database, the
hub keeps serving, and nothing surfaces -- which is how a broken updater goes
unnoticed for weeks.

**Delivery is unconfigured by default.** This host has no mail transport, and
guessing at one produces a notifier that fails silently, which is worse than
none. Set at most one of these in `/home/jupyterhub/etc/jupyterhub.env`:

| Variable | Use |
|---|---|
| `JH_NOTIFY_COMMAND` | Shell command receiving the report on stdin. The general case: `sendmail -t`, an SNS publish, a paging CLI. |
| `JH_NOTIFY_EMAIL` | Address to mail, via `mail(1)` or `sendmail(8)` if either is installed |
| `JH_NOTIFY_WEBHOOK` | URL to POST `{"text": "..."}` to. Slack-shaped; use `JH_NOTIFY_COMMAND` for any other payload format. |

With none set the report still reaches the journal, so
`journalctl -u 'jupyterhub-failure-notify@*'` always has it. The handler never
exits non-zero, so a broken notifier cannot produce a second failed unit.

Test it against a healthy unit without breaking anything:

```bash
sudo systemctl start jupyterhub-failure-notify@jupyterhub-update.service
sudo journalctl -u 'jupyterhub-failure-notify@*' -n 40 --no-pager
```

**Script**

* `/usr/local/sbin/jupyterhub-notify-failure.sh`

**Source of truth**

* `bin/notify-failure.sh` (in repo)

### Login banner

Delivery may be unconfigured, and the interesting case is a failure that
*recovered*: the rollback worked, the hub serves, users notice nothing, and the
only trace is in the journal. `/etc/update-motd.d/99-system-status` puts it in
front of the next person to log in over SSH.

`/usr/local/sbin/system-status` takes a command, defaulting to reporting:

```bash
system-status        # summary, plus anything needing attention
system-status ack    # acknowledge what was reported
```

The symlink at `/etc/update-motd.d/99-system-status` exists only because
`run-parts` needs a file in that directory. It passes no arguments, which is why
reporting is the default.

It always prints a summary -- hub version, active release, next scheduled
update -- so that its absence means the banner itself is broken rather than the
host being healthy. The version comes from the `dist-info` directory name rather
than `jupyterhub --version`, which would start a Python interpreter before every
login prompt.

Below that, and only when there is something to say, it reports three things:

| Signal | Why it is separate |
|---|---|
| Failed units (`systemctl --failed`) | Precise, but forgotten on `reset-failed` or reboot |
| `state/failures.log` entries since the last acknowledgement | Written by the failure handler, so it survives both |
| Newest release is not the active one | A failed activation leaves its staged release behind |

Acknowledge recorded failures once they have been understood:

```bash
system-status ack
```

That marks the recorded log acknowledged, then names any units still in a failed
state with the exact `journalctl` and `systemctl reset-failed` commands for each.
It deliberately does **not** run `reset-failed` itself: systemd's failed-unit
list is host-wide, and clearing it wholesale would discard the state of units
this project does not manage, hiding a failure nobody has looked at yet.

Underneath it is just a marker file, if you need it in a script:

```bash
touch /var/lib/eye-ai-compute/failures.acked
```

**Installed by** `install-jupyterhub-service.sh` from `bin/system-status.sh`.
The motd symlink drops the extension because `run-parts --lsbsysinit` skips
filenames containing dots.

---

## Authentication

### Globus (LocalGlobusOAuthenticator)

* Users authenticate via Globus
* UNIX users are auto-created on first login
* Group membership is enforced from Globus groups
* `/data/<username>` is provisioned on spawn

---

## Installation (Fresh DLAMI)

This deployment intentionally separates **ownership**, **execution**, and **runtime** responsibilities.
Following this order exactly avoids permission issues and broken installs.

### 1: Attach EBS volumes

Attach two EBS volumes:

| Purpose | Mount   |
|---------|---------|
| Home    | `/home` |
| Data    | `/data` |

---

### 2. Log in as the default DLAMI user and perform initial configuration

On a fresh DLAMI instance, log in as the default user (for example `ubuntu` or `ec2-user`).

* Obtain a root shell:
    ```shell
      sudo -i
    ```
* Set the hostname and timezone:
    ```shell
      hostnamectl set-hostname <your-desired-hostname>.eye-ai.org
      timedatectl set-timezone America/Los_Angeles
    ```
* Update the system. This step is _optional_ but recommended.
    ```shell
      apt-get update && apt-get upgrade -y
    ```
* Reboot
    ```shell
      reboot
    ```

---

### 3. Become root

All installation steps **must** be run as `root`.

Obtain a root shell:

```shell
  sudo -i
```

---

### 4. Clone the repository (as root)

```bash
git clone https://github.com/eye-ai-usc/eye-ai-compute-platform.git
cd eye-ai-compute-platform
```

Cloning as root avoids permission problems when deploying releases into
`/home/jupyterhub/releases`.

---

### 5. Run the installer

From the root shell:

```bash
./bin/install-all.sh 2>&1 | tee install-all.log
```

This command will:

1. Install mount scripts and systemd units
2. Mount `/home` and `/data` from EBS
3. Enable and verify ext4 user quotas on `/home`
4. Deploy JupyterHub into `/home/jupyterhub/releases/<timestamp>`
5. Install and enable JupyterHub and update services

---

## Important clarifications

* **Do not run installers as `jupyterhub`**
* **Do not use `sudo ./script.sh` from an unprivileged shell**
* Always run installers from a root shell (`sudo -i`)

### Responsibility breakdown

| Role           | Purpose                               |
|----------------|---------------------------------------|
| `root`         | Installation, mounts, quotas, systemd |
| `jupyterhub`   | Owns `/home/jupyterhub`               |
| Notebook users | Created dynamically at login          |
| systemd        | Starts and supervises JupyterHub      |

---

## After installation

Verify services:

```bash
systemctl status mount-ebs-volumes.service
systemctl status enable-home-quotas.service
systemctl status jupyterhub
systemctl status jupyterhub-update.timer
```

JupyterHub should be reachable at:

```
https://host/
```

---

## Deploying a New Release

From a checked-out repo:

```bash
./bin/install-jupyterhub-service.sh
```

This will:

* copy the repo into a new timestamped release
* install the systemd units from that release
* hand the release to `bin/activate-release.sh`, which builds the venv while the
  old release keeps serving, migrates the database, flips `current`, restarts
  JupyterHub, and verifies it is serving
* revert the symlink and restore the pre-migration database if it is not
* arm `jupyterhub-update.timer` **only** once the hub is verified
* print rollback instructions

Restarting the hub stops running single-user servers, so pick a window.

Nothing needs masking or disabling beforehand. The timer is armed last, and a
`Persistent=true` catch-up run firing afterwards takes the release lock, finds
no package change, discards what it built, and leaves the running hub alone.

### Rehearse the rollback before trusting it

That path only executes when something has already gone wrong, which is the
worst time to discover a bug in it. Force it deliberately, from a root shell --
a default sudoers policy rejects setting variables on a `sudo` command line:

```bash
sudo cp -a /home/jupyterhub/state/jupyterhub.sqlite /home/jupyterhub/state/backups/jupyterhub.sqlite.manual-pre-deploy
JH_HEALTH_TIMEOUT=10 ./bin/install-jupyterhub-service.sh
```

Ten seconds is not long enough for the hub to start, so verification fails on
purpose. You should land back on the previous release with the pre-migration
database restored, the timer unarmed, and an error saying so. Retention only
prunes `.auto.` copies, so the manual backup above survives regardless.

---

## Rollback

A failed deploy or update already reverts itself. This is for reverting a
release that deployed cleanly but turned out to be wrong.
`install-jupyterhub-service.sh` prints the exact command on success:

```bash
sudo ln -sfn /home/jupyterhub/releases/<timestamp> /home/jupyterhub/current && sudo systemctl restart jupyterhub
```

Rollback restores:

* code
* configuration
* Python dependencies
* update behavior

User data and state are untouched.

### The database is the exception

The hub database lives in shared state (`/home/jupyterhub/state/jupyterhub.sqlite`),
not in the release, so a symlink flip does **not** revert it. If the release you
are leaving had migrated the schema, the older hub cannot open the database and
will fail to start with:

```
Found database schema version <old> != <new>. Backup your database and run
`jupyterhub upgrade-db` to upgrade to the latest schema.
```

Restore the pre-migration copy alongside the symlink flip. `bootstrap-jupyterhub.sh`
writes one to `/home/jupyterhub/state/backups/jupyterhub.sqlite.auto.<timestamp>`
before every migration, and records the most recent path in
`/home/jupyterhub/state/.last-db-backup`. Only `.auto.` copies are subject to
retention, so a backup you take by hand under a different name is never pruned:

```bash
sudo systemctl stop jupyterhub
sudo cp -a "$(cat /home/jupyterhub/state/.last-db-backup)" /home/jupyterhub/state/jupyterhub.sqlite
sudo ln -sfn /home/jupyterhub/releases/<timestamp> /home/jupyterhub/current
sudo systemctl start jupyterhub
```

`update-jupyterhub-release.sh` does exactly this automatically when a hub it
just deployed fails to come back.

### The single-user venv is also shared

`/home/jupyterhub/state/user-venv` is shared state too, so a release rollback
does not revert `jupyterlab` or `jupyter_server` for user servers. If the hub is
healthy but notebooks misbehave after an update, reinstall there explicitly from
a recorded freeze in `/home/jupyterhub/state/backups/pip-freeze-user-*.txt`.

---

## Configuration

### Required environment variables

The directory `/home/jupyterhub/etc/` is created from the repository.
You must create `/home/jupyterhub/etc/jupyterhub.env` with deployment-specific
settings (secrets, hostnames, group IDs).


```bash
PUBLIC_HOSTNAME=compute.eye-ai.org
GLOBUS_CLIENT_ID=...
GLOBUS_CLIENT_SECRET=...
```

### Optional

```bash
ALLOWED_GROUPS=uuid1,uuid2
ADMIN_GROUPS=uuid3

# Failure notification -- set at most one; see jupyterhub-failure-notify@.service
JH_NOTIFY_COMMAND='sendmail -t'
JH_NOTIFY_EMAIL=isrd-support@isi.edu
JH_NOTIFY_WEBHOOK=https://hooks.slack.com/services/...
```

---

## Troubleshooting

### Check service status

```bash
systemctl status mount-ebs-volumes.service
systemctl status enable-home-quotas.service
systemctl status jupyterhub
systemctl status jupyterhub-update.service
systemctl --failed
```

### Logs

```bash
journalctl -u mount-ebs-volumes.service
journalctl -u enable-home-quotas.service
journalctl -u jupyterhub
journalctl -u jupyterhub-update.service
journalctl -u 'jupyterhub-failure-notify@*'
```

An upgrade's pip output is in `jupyterhub-update.service`, not in
`jupyterhub.service`. When a restart follows an update, the reason is in the
update unit's journal.

### Common issues

#### JupyterHub won’t start

* Check:

  * `/home` is mounted
  * quotas are enabled
  * `/home/jupyterhub/current` exists
* The service will **retry for transient failures** and **fail cleanly** for real configuration errors

#### A deploy or weekly update failed

It has already reverted itself: `current` is back on the previous release and the
pre-migration database has been restored. The hub should still be serving.

```bash
journalctl -u jupyterhub-update.service -n 80 --no-pager
readlink -f /home/jupyterhub/current /home/jupyterhub/previous
ls -lt /home/jupyterhub/state/backups/ | head
```

The staged release that failed is left in place for diagnosis and is pruned on a
later successful activation. If `JH_ROLLBACK_ON_FAILURE=0` was set, nothing was
reverted and the journal names the release to revert by hand.

#### Users get logged out on restart

* Check that:

  ```
  /home/jupyterhub/state/jupyterhub_cookie_secret
  ```

  exists and is persistent

#### Quotas not enforced

```bash
quotaon -p /home
repquota -u /home
```

Ensure `/home` is mounted with `usrquota`.

---

