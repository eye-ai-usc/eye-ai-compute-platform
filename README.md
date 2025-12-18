# eye-ai-compute-platform

### AWS DLAMI + JupyterHub for GPU-enabled collaborative compute workloads.

---
This repository provides a host-native JupyterHub deployment for AWS DLAMI instances with:

* persistent `/home` and `/data` on EBS
* ext4 user quotas on `/home`
* systemd-managed services
* per-release, revertable JupyterHub installs
* Globus authentication with automatic UNIX user provisioning

The primary goal is **easy DLAMI upgrades** with **zero data loss** and **minimal moving parts**.

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
   * Switching releases is a symlink flip + service restart

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
        ├── pid/
        ├── logs/
        └── user-venv/
```

### Root filesystem (reproducible)

```
/usr/local/sbin/
├── mount-ebs-volumes.sh
└── enable-home-quotas.sh

/etc/systemd/system/
├── mount-ebs-volumes.service
├── enable-home-quotas.service
└── jupyterhub.service
```

All rootfs files are installed from this repo via installer scripts.

---

## Boot Order (systemd)

```
mount-ebs-volumes.service
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

* Format EBS devices if needed
* Mount:

  * `/home`
  * `/data`
* Optionally configure NVMe swap
* Add `/etc/fstab` entries

**Script**

* `/usr/local/sbin/mount-ebs-volumes.sh`

**Source of truth**

* `scripts/mount-ebs-volumes.sh` (in repo)

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
* Limited to **one restart attempt** on failure

**Bootstrap behavior**

* `ExecStartPre` runs `bin/bootstrap-jupyterhub.sh`
* Ensures:

  * venv exists
  * hub packages installed
  * cookie secret present

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
./bin/install-all.sh
```

This command will:

1. Install mount scripts and systemd units
2. Mount `/home` and `/data` from EBS
3. Enable and verify ext4 user quotas on `/home`
4. Deploy JupyterHub into `/home/jupyterhub/releases/<timestamp>`
5. Enable and start all required systemd services

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
```

JupyterHub should now be reachable at:

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
* update `/home/jupyterhub/current`
* restart JupyterHub
* print rollback instructions

---

## Rollback

Example output:

```bash
Rollback (copy/paste):
  sudo ln -sfn /home/jupyterhub/releases/20250101T120000Z /home/jupyterhub/current \
  && sudo systemctl restart jupyterhub
```

Rollback restores:

* code
* configuration
* Python dependencies

User data and state are untouched.

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
```

---

## Troubleshooting

### Check service status

```bash
systemctl status mount-ebs-volumes.service
systemctl status enable-home-quotas.service
systemctl status jupyterhub
```

### Logs

```bash
journalctl -u mount-ebs-volumes.service
journalctl -u enable-home-quotas.service
journalctl -u jupyterhub
```

### Common issues

#### JupyterHub won’t start

* Check:

  * `/home` is mounted
  * quotas are enabled
  * `/home/jupyterhub/current` exists
* The service will **fail cleanly** if any prerequisite is missing

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

