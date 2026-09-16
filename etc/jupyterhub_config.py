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

# Spawn through a wrapper so the UMASK set in _pre_spawn_hook actually takes
# effect. umask is a process attribute, not an environment variable, so it
# needs a shell between the spawner and the server binary -- exec'ing
# jupyterhub-singleuser directly leaves UMASK inert and the kernel inherits
# systemd's default 0022. SINGLEUSER_BIN keeps the real path in one place.
SINGLEUSER_BIN = os.environ.get(
    "JH_SINGLEUSER_BIN", "/home/jupyterhub/current/venv/bin/jupyterhub-singleuser"
)
c.Spawner.cmd = [
    os.environ.get("JH_SPAWN_WRAPPER", "/home/jupyterhub/current/bin/spawn-singleuser.sh")
]
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
# 0002 == group-writable. 0022 ("group read-only") was correct while the
# deriva-ml bag cache shared by directory glob: a second user only ever read
# another user's cached bag, so group-read was sufficient. deriva-ml v1.35.0
# replaced the glob with a WAL SQLite index that is opened read-write even to
# consume a cache hit, which made group-read-only a silent no-share.
DEFAULT_UMASK = os.environ.get("DEFAULT_UMASK", "0002")

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


async def _pre_spawn_hook(spawner):
    username = spawner.user.name
    log.info("pre_spawn_hook: provisioning user '%s'", username)

    subprocess.check_call(["id", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    ensure_group(JUPYTER_GROUP, JUPYTER_GID)
    ensure_user_in_group(username, JUPYTER_GROUP)
    ensure_data_dir(username, JUPYTER_GROUP)
    ensure_home_quota(username)

    spawner.environment = spawner.environment or {}
    spawner.environment["UMASK"] = DEFAULT_UMASK
    spawner.environment["SINGLEUSER_BIN"] = SINGLEUSER_BIN


c.Spawner.pre_spawn_hook = _pre_spawn_hook
