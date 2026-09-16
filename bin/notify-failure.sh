#!/usr/bin/env bash
set -uo pipefail

# Report a failed systemd unit.
#
# Invoked by jupyterhub-failure-notify@.service, which units reference with
#   OnFailure=jupyterhub-failure-notify@%n.service
#
# The automation recovers on its own -- a failed weekly update rolls back to the
# previous release and restores the pre-migration database -- so the hub keeps
# serving and nothing surfaces. Without this, a failure sits in the journal until
# somebody happens to look, which is how a silently broken updater goes unnoticed
# for weeks.
#
# Delivery is deliberately mechanism-agnostic: this host has no mail transport
# configured, and guessing at one would produce a notifier that fails silently,
# which is worse than none. Set one of these in /home/jupyterhub/etc/jupyterhub.env:
#
#   JH_NOTIFY_COMMAND   shell command receiving the report on stdin. The general
#                       case: sendmail, an SNS publish, a paging CLI, anything.
#   JH_NOTIFY_EMAIL     address to mail, using mail(1) or sendmail(8) if present
#   JH_NOTIFY_WEBHOOK   URL to POST {"text": "..."} to (Slack-shaped; use
#                       JH_NOTIFY_COMMAND for any other payload format)
#
# With none set, the report still goes to the journal under this unit, so
# `journalctl -u jupyterhub-failure-notify@*` always has it. This never exits
# non-zero: a failing notifier must not produce a second failed unit.

UNIT="${1:-unknown.service}"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
WHEN="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"

SUBJECT="[${HOSTNAME_FQDN}] ${UNIT} failed"

REPORT="$(
	echo "Unit:   ${UNIT}"
	echo "Host:   ${HOSTNAME_FQDN}"
	echo "When:   ${WHEN}"
	echo
	echo "--- systemctl status ---"
	systemctl status "$UNIT" --no-pager --lines=0 2>&1 | head -20
	echo
	echo "--- last 50 journal lines (this boot) ---"
	journalctl -u "$UNIT" -b 0 -n 50 --no-pager 2>&1
)"

# Always land in the journal, whatever else happens.
echo "$SUBJECT"
echo "$REPORT"

# Record it durably too. systemctl --failed forgets a unit on reset-failed or
# reboot; this file is what the login banner reads, so a failure stays visible
# until somebody acknowledges it. Capped so it cannot grow without bound.
STATE_DIR="/var/lib/eye-ai-compute"
FAILURE_LOG="${STATE_DIR}/failures.log"
if mkdir -p "$STATE_DIR" 2>/dev/null; then
	echo "${WHEN}  ${UNIT}" >> "$FAILURE_LOG" 2>/dev/null || true
	if [[ "$(wc -l < "$FAILURE_LOG" 2>/dev/null || echo 0)" -gt 200 ]]; then
		if tail -n 200 "$FAILURE_LOG" > "${FAILURE_LOG}.tmp" 2>/dev/null; then
			mv "${FAILURE_LOG}.tmp" "$FAILURE_LOG" 2>/dev/null || true
		fi
	fi
fi

deliver_command() {
	printf '%s\n\n%s\n' "$SUBJECT" "$REPORT" | sh -c "$JH_NOTIFY_COMMAND"
}

deliver_email() {
	if command -v mail >/dev/null 2>&1; then
		printf '%s\n' "$REPORT" | mail -s "$SUBJECT" "$JH_NOTIFY_EMAIL"
	elif command -v sendmail >/dev/null 2>&1; then
		printf 'To: %s\nSubject: %s\n\n%s\n' \
			"$JH_NOTIFY_EMAIL" "$SUBJECT" "$REPORT" | sendmail -t
	else
		echo "[notify-failure] JH_NOTIFY_EMAIL is set but neither mail nor sendmail is installed" >&2
		return 1
	fi
}

# Send a readable excerpt rather than the whole report: Slack caps message length
# and renders a long one poorly. The full text is in this unit's journal either
# way, since it is echoed above before any delivery is attempted.
deliver_webhook() {
	local payload
	payload="$(python3 -c '
import json, sys

body = sys.stdin.read()
limit = 3000
if len(body) > limit:
    body = body[:limit] + "\n\n[truncated -- full report: journalctl -u jupyterhub-failure-notify@*]"
print(json.dumps({"text": body}))
' <<<"${SUBJECT}"$'\n\n'"${REPORT}")" || return 1
	curl -fsS --max-time 15 -X POST -H 'Content-Type: application/json' -d "$payload" "$JH_NOTIFY_WEBHOOK" >/dev/null
}

delivered=0
if [[ -n "${JH_NOTIFY_COMMAND:-}" ]]; then
	deliver_command && delivered=1 || echo "[notify-failure] JH_NOTIFY_COMMAND failed" >&2
elif [[ -n "${JH_NOTIFY_EMAIL:-}" ]]; then
	deliver_email && delivered=1 || echo "[notify-failure] email delivery failed" >&2
elif [[ -n "${JH_NOTIFY_WEBHOOK:-}" ]]; then
	deliver_webhook && delivered=1 || echo "[notify-failure] webhook delivery failed" >&2
else
	echo "[notify-failure] no delivery method configured; report is in this unit's journal only" >&2
fi

if (( delivered == 1 )); then
	echo "[notify-failure] report delivered"
fi

exit 0
