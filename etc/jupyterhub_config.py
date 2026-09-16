import os
import subprocess
import traitlets.log
from oauthenticator.globus import LocalGlobusOAuthenticator

c = get_config()  # noqa
log = traitlets.log.get_logger()

# --- Core Hub / Proxy / Base URL ---
c.JupyterHub.bind_url = "http://127.0.0.1:8000"
c.JupyterHub.base_url = "/"
c.JupyterHub.trusted_downstream_ips = ["127.0.0.1"]


# --- Metrics & state (shared across releases) ---
STATE_DIR = os.environ.get("JH_STATE_DIR", "/home/jupyterhub/state")
c.JupyterHub.cookie_secret_file = os.path.join(STATE_DIR, "jupyterhub_cookie_secret")
c.JupyterHub.db_url = f"sqlite:///{os.path.join(STATE_DIR, 'jupyterhub.sqlite')}"
c.JupyterHub.authenticate_prometheus = False

# --- Auth: Globus (LocalGlobusOAuthenticator) ---
c.JupyterHub.authenticator_class = LocalGlobusOAuthenticator

public_base = "https://" + os.environ.get("PUBLIC_HOSTNAME", "localhost")
# With base_url="/", callback is always /hub/oauth_callback
c.OAuthenticator.oauth_callback_url = os.environ.get(
    "OAUTH_CALLBACK_URL",
    f"{public_base}/hub/oauth_callback",
)

c.GlobusOAuthenticator.client_id = os.environ.get("GLOBUS_CLIENT_ID")
c.GlobusOAuthenticator.client_secret = os.environ.get("GLOBUS_CLIENT_SECRET")
c.GlobusOAuthenticator.scope = [
    "openid",
    "https://auth.globus.org/scopes/www.eye-ai.org/deriva_all",
]
c.GlobusOAuthenticator.exclude_tokens = ["auth.globus.org"]

# Logout returns to https://host/
c.GlobusOAuthenticator.logout_redirect_url = (
    "https://auth.globus.org/v2/web/logout?redirect_uri="
    + f"{public_base}/"
    + "&redirect_name=EYE-AI JupyterHub"
)
c.GlobusOAuthenticator.revoke_tokens_on_logout = False

def _split_env_list(name: str):
    raw = os.environ.get(name, "").strip()
    return [x.strip() for x in raw.split(",") if x.strip()]

c.GlobusOAuthenticator.allowed_globus_groups = _split_env_list("ALLOWED_GROUPS")
c.GlobusOAuthenticator.admin_globus_groups = _split_env_list("ADMIN_GROUPS")

# Auto-create system users
c.LocalGlobusOAuthenticator.create_system_users = True
c.Authenticator.delete_invalid_users = True

# Non-interactive adduser on Ubuntu; overrideable
c.LocalGlobusOAuthenticator.add_user_cmd = os.environ.get(
    "ADD_USER_CMD",
    "adduser --disabled-password --gecos ''",
).split()

# --- Spawner ---
USER_VENV = os.environ.get("JH_USER_VENV", "/home/jupyterhub/state/user-venv")
c.JupyterHub.spawner_class = "jupyterhub.spawner.LocalProcessSpawner"
c.Spawner.default_url = "/lab"
c.Spawner.cmd = ["/home/jupyterhub/current/venv/bin/jupyterhub-singleuser"]
# Prepend user venv bin to existing PATH
_existing_path = os.environ.get("PATH", "")
_prepend = f"{USER_VENV}/bin"
if _existing_path:
    path = f"{_prepend}:{_existing_path}"
else:
    path = _prepend
c.Spawner.environment = c.Spawner.environment or {}
c.Spawner.environment.update({
    "VIRTUAL_ENV": USER_VENV,
    "PATH": path,
    "PYTHONUNBUFFERED": "1",
    "JUPYTERHUB_SINGLEUSER_APP": "jupyter_server.serverapp.ServerApp",
})

# --- Shared data provisioning ---
DATA_ROOT = os.environ.get("DATA_ROOT", "/data")
JUPYTER_GID = os.environ.get("JUPYTER_GID", "900")
JUPYTER_GROUP = os.environ.get("JUPYTER_GROUP", "jupyter")
DEFAULT_UMASK = os.environ.get("DEFAULT_UMASK", "0022")  # group read-only

def _run(*args: str):
    subprocess.check_call(list(args))


def ensure_group(group: str, gid: str):
    try:
        _run("groupadd", "-f", "-g", str(gid), group)
    except Exception as e:
        log.error("Failed to ensure group %s (gid=%s): %s", group, gid, e)


def ensure_user_in_group(username: str, group: str):
    try:
        _run("usermod", "-aG", group, username)
    except Exception as e:
        log.error("Failed to add user %s to group %s: %s", username, group, e)


def ensure_data_dir(username: str, group: str):
    user_dir = os.path.join(DATA_ROOT, username)
    try:
        _run("mkdir", "-p", user_dir)
        _run("chown", f"{username}:{group}", user_dir)
        _run("chmod", "2755", user_dir)  # drwxr-sr-x
    except Exception as e:
        log.error("Failed to ensure data dir for %s at %s: %s", username, user_dir, e)


# --- Home quota provisioning ---
#
# enable-home-quotas.service applies limits by looping /etc/passwd, so it only
# covers accounts that exist when it runs -- at boot. Accounts are created on
# first Globus login, so between boots a new user has no limit at all. On a host
# with multi-week uptime that gap is wide enough for someone to fill /home.
#
# Applying the limit here closes it: the first spawn sets it, rather than the
# next reboot.
#
# The marker file is what keeps this from clobbering a deliberately raised
# limit. Once a user has been provisioned we never touch their quota again, so
# `setquota -u someone <bigger>` by hand is permanent. It lives under state/ on
# the EBS volume so it survives an AMI refresh; losing it would mean the next
# spawn resets that user to the defaults.
QUOTA_FS = os.environ.get("HOME_QUOTA_FS", "/home")
QUOTA_SOFT_KIB = os.environ.get("QUOTA_SOFT_KIB", str(50 * 1024 * 1024))
QUOTA_HARD_KIB = os.environ.get("QUOTA_HARD_KIB", str(60 * 1024 * 1024))
QUOTA_MARKER_DIR = os.path.join(STATE_DIR, "quota-provisioned")


def ensure_home_quota(username: str):
    marker = os.path.join(QUOTA_MARKER_DIR, username)
    if os.path.exists(marker):
        return
    try:
        _run(
            "setquota", "-u", username,
            QUOTA_SOFT_KIB, QUOTA_HARD_KIB, "0", "0", QUOTA_FS,
        )
        os.makedirs(QUOTA_MARKER_DIR, exist_ok=True)
        with open(marker, "w") as fh:
            fh.write(f"{QUOTA_SOFT_KIB} {QUOTA_HARD_KIB} {QUOTA_FS}\n")
        log.info(
            "Applied home quota for %s: %s/%s KiB on %s",
            username, QUOTA_SOFT_KIB, QUOTA_HARD_KIB, QUOTA_FS,
        )
    except Exception as e:
        # Not fatal. A quota that failed to apply is worth knowing about, but it
        # is not a reason to refuse somebody their notebook.
        log.error("Failed to set home quota for %s: %s", username, e)


# --- uv cache on the instance-store NVMe ---
#
# uv's cache grows without bound as people build environments, and in a home
# directory it counts against the quota: it accounted for 24 GB of one user's
# 132 GB. A build cache is regenerable, so the instance store is the right place
# for it -- faster than the EBS home volume, outside the quota, and wiped on
# stop/start, which for a cache is correct rather than a drawback. It also gives
# that volume the scratch use it is mounted for.
#
# Note that uv hardlinks from its cache into venv site-packages. Moving the cache
# to a different filesystem means it copies instead, so a user's existing venvs
# keep their own copies and only new builds benefit.
NVME_SCRATCH = os.environ.get("NVME_SCRATCH", "/opt/dlami/nvme")
UV_CACHE_ROOT = os.path.join(NVME_SCRATCH, "uv-cache")


def ensure_uv_cache_dir(username: str, group: str):
    """Per-user uv cache on the instance store. Returns the path, or None."""
    if not os.path.ismount(NVME_SCRATCH):
        # Instance store absent or unmounted. Leaving UV_CACHE_DIR unset falls
        # back to ~/.cache/uv, which works -- it just counts against the quota.
        log.warning(
            "%s is not a mountpoint; leaving uv cache in the home directory",
            NVME_SCRATCH,
        )
        return None
    cache_dir = os.path.join(UV_CACHE_ROOT, username)
    try:
        _run("mkdir", "-p", cache_dir)
        _run("chown", f"{username}:{group}", cache_dir)
        _run("chmod", "0700", cache_dir)
        return cache_dir
    except Exception as e:
        log.error("Failed to ensure uv cache dir for %s at %s: %s", username, cache_dir, e)
        return None


async def _pre_spawn_hook(spawner):
    username = spawner.user.name
    log.info("pre_spawn_hook: provisioning user '%s'", username)

    subprocess.check_call(["id", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    ensure_group(JUPYTER_GROUP, JUPYTER_GID)
    ensure_user_in_group(username, JUPYTER_GROUP)
    ensure_data_dir(username, JUPYTER_GROUP)
    ensure_home_quota(username)
    uv_cache = ensure_uv_cache_dir(username, JUPYTER_GROUP)

    spawner.environment = spawner.environment or {}
    spawner.environment["UMASK"] = DEFAULT_UMASK
    if uv_cache:
        spawner.environment["UV_CACHE_DIR"] = uv_cache


c.Spawner.pre_spawn_hook = _pre_spawn_hook
