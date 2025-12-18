import os
import subprocess
import traitlets.log
from oauthenticator.globus import LocalGlobusOAuthenticator

c = get_config()  # noqa
log = traitlets.log.get_logger()

# --- Core Hub / Proxy / Base URL ---
c.JupyterHub.bind_url = "http://127.0.0.1:8000"
c.JupyterHub.base_url = "/"
c.JupyterHub.trusted_downstream = ["127.0.0.1"]


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


async def _pre_spawn_hook(spawner):
    username = spawner.user.name
    log.info("pre_spawn_hook: provisioning user '%s'", username)

    subprocess.check_call(["id", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    ensure_group(JUPYTER_GROUP, JUPYTER_GID)
    ensure_user_in_group(username, JUPYTER_GROUP)
    ensure_data_dir(username, JUPYTER_GROUP)

    spawner.environment = spawner.environment or {}
    spawner.environment["UMASK"] = DEFAULT_UMASK


c.Spawner.pre_spawn_hook = _pre_spawn_hook
