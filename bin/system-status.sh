#!/usr/bin/env bash
set -uo pipefail

# Report, and acknowledge, failures the automation already recovered from.
#
#   system-status          report (default; what the login banner runs)
#   system-status ack      acknowledge what was reported
#
# Installed at /usr/local/sbin/system-status, with a symlink at
# /etc/update-motd.d/99-system-status so pam_motd runs it on login. That symlink
# exists only because run-parts needs a file in that directory; it takes no
# arguments, which is why reporting is the default. run-parts --lsbsysinit skips
# filenames containing dots, hence the extensionless name.
#
# The 99 is deliberate. run-parts sorts lexically, so this lands after the DLAMI
# banner at 99-motd and prints last, immediately above the prompt -- the most
# visible slot for the ATTENTION blocks, and directly beneath the banner whose
# layout this one matches.
#
# Why this exists: a failed deploy or weekly update rolls back on its own, so the
# hub keeps serving and nothing surfaces. The evidence sits in the journal until
# somebody thinks to look.
#
# Two sources, because they decay differently. `systemctl --failed` is precise
# but forgotten on reset-failed or reboot. The log written by notify-failure.sh
# persists, so a failure that has since been cleared still gets reported until
# acknowledged.

STATE_DIR="/var/lib/eye-ai-compute"
FAILURE_LOG="${STATE_DIR}/failures.log"
ACK_MARKER="${STATE_DIR}/failures.acked"

# Instance-store scratch. Reported because it holds the per-user uv caches, which
# are not quota'd: unlike a home directory, one user filling this breaks builds
# for everyone. Better to see it climbing at login than to find out when uv
# starts failing.
SCRATCH_DIR="${SCRATCH_DIR:-/opt/dlami/nvme}"
SCRATCH_WARN_PCT="${SCRATCH_WARN_PCT:-85}"

usage() {
	cat <<'EOF'
Usage: system-status [command]

  (no command)   summary, plus anything needing attention
  ack            acknowledge recorded failures
  help           this message
EOF
}

failed_units() {
	systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}'
}

# True when the log holds entries newer than the last acknowledgement.
unacknowledged() {
	[[ -s "$FAILURE_LOG" ]] || return 1
	[[ -f "$ACK_MARKER" ]] || return 0
	[[ "$FAILURE_LOG" -nt "$ACK_MARKER" ]]
}

# ------------------------------------------------------------------ report ---

# Read the hub version from the dist-info directory name rather than running
# `jupyterhub --version`, which starts a Python interpreter. This runs before
# every login prompt, so everything here has to stay cheap.
hub_version() {
	local d
	d="$(ls -1d /home/jupyterhub/current/venv/lib/python3*/site-packages/jupyterhub-*.dist-info 2>/dev/null | head -n1)"
	[[ -n "$d" ]] || return 1
	d="$(basename "$d")"
	d="${d#jupyterhub-}"
	printf '%s' "${d%.dist-info}"
}

# Laid out to sit alongside the DLAMI banner this host already prints: a rule
# above and below, "Label: value" lines, blank-line-separated blocks, no
# decoration. The only colour is on ATTENTION, and only for a terminal.
RULE="============================================================================="

report() {
	local red="" off=""
	if [[ -t 1 ]]; then
		red=$'\033[1;31m'; off=$'\033[0m'
	fi

	# Always print the summary. Printing nothing when healthy makes "healthy"
	# indistinguishable from "this script is broken"; a line that is always there
	# is a line whose absence means something.
	local version state since release nextrun
	version="$(hub_version || echo unknown)"
	state="$(systemctl is-active jupyterhub 2>/dev/null || true)"
	since="$(systemctl show jupyterhub -p ActiveEnterTimestamp --value 2>/dev/null || true)"
	release="$(basename "$(readlink -f /home/jupyterhub/current 2>/dev/null || echo unknown)")"
	nextrun="$(systemctl list-timers jupyterhub-update.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3, $4}')"

	# Leading blank line so the top rule does not butt against the closing rule
	# of whatever printed before, usually the DLAMI banner at 99-motd.
	printf '\n%s\n' "$RULE"
	printf 'JupyterHub version: %s\n' "$version"
	if [[ "$state" == "active" ]]; then
		printf 'Service state: active since %s\n' "${since:-unknown}"
	else
		printf 'Service state: %s%s%s\n' "$red" "${state:-unknown}" "$off"
	fi
	printf 'Active release: %s\n' "$release"
	[[ -n "$nextrun" ]] && printf 'Next scheduled update: %s\n' "$nextrun"

	local scratch_pct scratch_free
	scratch_pct="$(df --output=pcent "$SCRATCH_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')"
	scratch_free="$(df -h --output=avail "$SCRATCH_DIR" 2>/dev/null | tail -1 | tr -d ' ')"
	if [[ -n "$scratch_pct" ]]; then
		printf 'Scratch %s: %s%% used, %s free\n' "$SCRATCH_DIR" "$scratch_pct" "${scratch_free:-?}"
	fi

	local shown=0
	local failed unit
	failed="$(failed_units)"
	if [[ -n "$failed" ]]; then
		shown=1
		printf '\n%sATTENTION: failed units%s\n' "$red" "$off"
		while read -r unit; do
			[[ -n "$unit" ]] || continue
			printf '  %s\n' "$unit"
		done <<<"$failed"
		printf '  Inspect: journalctl -u <unit> -n 50 --no-pager\n'
	fi

	if unacknowledged; then
		shown=1
		printf '\n%sATTENTION: recorded failures since last acknowledgement%s\n' "$red" "$off"
		tail -n 5 "$FAILURE_LOG" | sed 's/^/  /'
		printf '  Inspect: journalctl -u "jupyterhub-failure-notify@*" -n 50 --no-pager\n'
	fi

	# A staged release left behind means a deploy or update did not complete and
	# nobody has redeployed since.
	local current newest
	current="$(readlink -f /home/jupyterhub/current 2>/dev/null || true)"
	if [[ -n "$current" && -d /home/jupyterhub/releases ]]; then
		newest="$(find /home/jupyterhub/releases -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -n1)"
		if [[ -n "$newest" && "$newest" != "$current" ]]; then
			shown=1
			printf '\n%sATTENTION: newest release is not the active one%s\n' "$red" "$off"
			printf '  Active: %s\n' "$current"
			printf '  Newest: %s\n' "$newest"
			printf '  A failed activation leaves its staged release behind.\n'
		fi
	fi

	# The uv caches under here are shared and unquota'd, so a full volume is
	# everyone's problem rather than one user's.
	if [[ -n "$scratch_pct" ]] && (( scratch_pct >= SCRATCH_WARN_PCT )); then
		shown=1
		printf '\n%sATTENTION: scratch volume %s%% full%s\n' "$red" "$scratch_pct" "$off"
		printf '  %s holds the per-user uv caches and is not quota-limited.\n' "$SCRATCH_DIR"
		printf '  Largest: du -sh %s/uv-cache/* | sort -h | tail\n' "$SCRATCH_DIR"
		printf '  Reclaim: systemctl start prune-uv-caches\n'
	fi

	if (( shown == 1 )); then
		printf '\nAcknowledge once understood: system-status ack\n'
	fi
	printf '%s\n' "$RULE"
}

# --------------------------------------------------------------- acknowledge --

acknowledge() {
	if [[ "${EUID}" -ne 0 ]]; then
		echo "system-status ack: must run as root" >&2
		return 1
	fi

	if [[ -s "$FAILURE_LOG" ]]; then
		echo "Acknowledging recorded failures. Most recent:"
		tail -n 5 "$FAILURE_LOG" | sed 's/^/  /'
	else
		echo "No recorded failures."
	fi

	mkdir -p "$STATE_DIR" || return 1
	touch "$ACK_MARKER" || return 1
	echo "Marked acknowledged at $(date -u +'%Y-%m-%d %H:%M:%S UTC')."

	local failed unit
	failed="$(failed_units)"
	if [[ -z "$failed" ]]; then
		echo "No units are in a failed state."
		return 0
	fi

	# Deliberately not run here: systemd's failed-unit list is host-wide, so
	# clearing it wholesale would discard the state of units this project does
	# not manage, hiding a failure nobody has looked at yet.
	echo ""
	echo "Units still in a failed state. The banner reports these until systemd's"
	echo "own record is cleared, which is left to you:"
	echo ""
	while read -r unit; do
		[[ -n "$unit" ]] || continue
		printf '  journalctl -u %s -n 50 --no-pager\n' "$unit"
		printf '  systemctl reset-failed %s\n\n' "$unit"
	done <<<"$failed"
}

case "${1:-}" in
	# No argument is the login-banner path, which must never fail a login.
	"")             report; exit 0 ;;
	ack)            acknowledge; exit $? ;;
	help|-h|--help) usage; exit 0 ;;
	*)
		echo "system-status: unknown command: $1" >&2
		usage >&2
		exit 2
		;;
esac
