#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The outside view: check the hub from this droplet, tell the hub what was seen, and
# email a person when the hub cannot be reached — in that order, with the email never
# depending on the hub.
#
# 🚨 **Why this runs here rather than on the hub.** Every check a process makes about
# itself shares a failure domain with that process. When App Platform is the problem, the
# hub's own /health is unreachable along with everything else on it. This droplet is a
# different failure domain — it runs the identity server, not the hub — which is the whole
# qualification for the job. The counterpart design lives in the hub's
# `apps/api/src/services/heartbeat.ts`: the hub stores this script's verdicts and renders
# them on the public /status page, with a staleness window so a dead monitor reads as
# "unknown" rather than all-clear.
#
# ⚠️ **The email is deliberate, and it is the alerting half, not a duplicate.** Reporting
# the verdict to the hub depends on the hub being up; the email does not. On a verdict of
# down (or a failure to check at all), this script sends one short email through Resend
# on the node's own key, straight to OPS_ALERT_EMAIL — the same mailbox every other
# operational alert uses. A verdict of degraded likewise, once per outage rather than per
# check (a tiny state file remembers what was last reported, so the noise floor stays
# honest: a site down for four hours emails when it goes down and when it comes back,
# not every minute in between).
#
# Installation (operator, once — see the Runbook's § on this script):
#
#   1. Generate the shared secret on your own machine, set it in two places:
#        openssl rand -hex 32
#      - the hub's HEARTBEAT_TOKEN secret (Bitwarden prod project + App Platform), and
#      - HEARTBEAT_TOKEN in the env file this script reads (below).
#   2. Lay the file in: /pds/heartbeat/{heartbeat-check.sh,heartbeat.env,heartbeat.state}
#      with the env file holding HEARTBEAT_TOKEN, OPS_ALERT_EMAIL and the node's mail vars.
#   3. Run it every minute from cron as root:
#        * * * * * /pds/heartbeat/heartbeat-check.sh
#      (a systemd timer serves identically; cron was chosen because the node's backup
#      file timer is already cron and one scheduling system per box is one to debug).
#
# Secrets never appear on a command line or in this file: they are read from the env file,
# which is chmod 0600, same discipline as /pds/pds.env.
#
# After the check, verdict report and alerts, this script also regenerates the standalone
# public status page (scripts/status-page.sh → /pds/status/index.html), so the page at
# status.anthers.org is exactly as fresh as the outside verdict. See that script for why
# the page lives here.

set -euo pipefail

HEARTBEAT_DIR="${HEARTBEAT_DIR:-/pds/heartbeat}"
# shellcheck source=/dev/null
source "${HEARTBEAT_DIR}/heartbeat.env"

STATE_FILE="${HEARTBEAT_DIR}/heartbeat.state"

# What the hub's deepened /health answers, and what this script treats as failure.
# A 503 is the hub telling the truth about itself (down); any non-200 is checked-from-
# outside failure; a refused connection is the platform being unreachable, which is the
# case this whole arrangement exists to catch.
HUB_HEALTH_URL="${HUB_HEALTH_URL:-https://anthers.org/health}"
TIMEOUT_SECS="${TIMEOUT_SECS:-10}"

# ── Mail, through the node's own Resend key ──────────────────────────────────────────
# The port is 2465 and it is not a preference: DigitalOcean blocks outbound 25/465/587,
# and the failure mode of the blocked ports is a hang, not a refusal (the Runbook
# documents the 44-second silent hang that taught this). Send one short plain-text mail.
#
# ⚠️ **The key this uses is the node's own restricted Resend key — the user part of the
# node's SMTP URL (`PDS_EMAIL_SMTP_URL` in /pds/pds.env), NOT the hub's `RESEND_API_KEY`.**
# The hub's key sends as anthers.org and lives only in the vault with it; the node's key
# is restricted to anthers.social (the Runbook's § Mail) and is what this droplet is
# allowed to say mail from. The env example below reads it from its own line in
# heartbeat.env; the operator copies it out of the SMTP URL's userinfo when laying the
# file in — the smtps:// URL is the credential store this box already holds.

send_alert() {
	local subject="$1"
	local body="$2"
	if [[ -z "${RESEND_API_KEY:-}" || -z "${OPS_ALERT_EMAIL:-}" ]]; then
		echo "heartbeat: RESEND_API_KEY or OPS_ALERT_EMAIL unset — nobody was told: ${subject}" >&2
		return 0
	fi
	# A minute is all a curl to Resend needs; a mail that hangs must not wedge the check.
	local payload
	payload=$(printf '{"from":"Anthers heartbeat <noreply@anthers.social>","to":["%s"],"subject":"%s","text":"%s"}' \
		"${OPS_ALERT_EMAIL}" "${subject}" "${body}")
	curl -sS --max-time 30 -X POST "https://api.resend.com/emails" \
		-H "Authorization: Bearer ${RESEND_API_KEY}" \
		-H "Content-Type: application/json" \
		-d "${payload}" > /dev/null 2>&1 || echo "heartbeat: alert send failed for: ${subject}" >&2
}

# ── The verdict state file — one line per field, so a read is a source, not a parse ──

read_state() {
	# Defaults for a first run: nothing reported, never alerted.
	LAST_VERDICT="none"
	: > /dev/null
	if [[ -f "${STATE_FILE}" ]]; then
		# shellcheck source=/dev/null
		source "${STATE_FILE}"
	fi
}

write_state() {
	local verdict="$1"
	local alerted="$2"
	printf 'LAST_VERDICT=%q\nLAST_ALERTED=%q\n' "${verdict}" "${alerted}" > "${STATE_FILE}"
}

# ── The check ────────────────────────────────────────────────────────────────────────

read_state

HTTP_CODE=""
BODY=""
HTTP_CODE=$(curl -sS --max-time "${TIMEOUT_SECS}" -o "${HEARTBEAT_DIR}/.last-body" -w "%{http_code}" \
	"${HUB_HEALTH_URL}" 2>/dev/null) || HTTP_CODE="000"
BODY=$(cat "${HEARTBEAT_DIR}/.last-body" 2>/dev/null || echo "")

# The hub's overall state, as /health's JSON names it; parse defensively, because a hub
# that answers 200 with unparseable JSON is a hub being honest about some degradation.
# 🚨 `|| true` on the pipeline is load-bearing, not decoration: a /health that answers
# 200 with NO "state" field (the pre-deepening shape, or any older release behind a
# rolling deploy) makes grep exit 1 — and under `set -euo pipefail` that would kill the
# script mid-run, BEFORE the alert and the report ever fire. No match is a fact to
# handle, not an error to die on: no state field reads as "the hub did not say", and
# the verdict stays up on a 200.
REPORTED_STATE=$(printf '%s' "${BODY}" | grep -o '"state":"[a-z]*"' | head -1 | cut -d'"' -f4 || true)

VERDICT="up"
DETAIL=""
if [[ "${HTTP_CODE}" == "000" ]]; then
	VERDICT="down"
	DETAIL="anthers.org did not answer within ${TIMEOUT_SECS}s — the health check could not connect."
elif [[ "${HTTP_CODE}" == "503" ]]; then
	VERDICT="down"
	DETAIL="anthers.org /health answered 503 — the hub reports a component down."
elif [[ "${HTTP_CODE}" != "200" ]]; then
	VERDICT="down"
	DETAIL="anthers.org /health answered HTTP ${HTTP_CODE}."
elif [[ "${REPORTED_STATE}" == "down" ]]; then
	VERDICT="down"
	DETAIL="anthers.org /health answered 200 with state \"down\"."
elif [[ "${REPORTED_STATE}" == "degraded" ]]; then
	VERDICT="degraded"
	DETAIL="anthers.org /health answered 200 with state \"degraded\"."
fi

# ── Report upstream, and alert on the transition — the noise floor's whole design ────

report_upstream() {
	local verdict="$1"
	local detail="$2"
	if [[ -z "${HUB_HEARTBEAT_URL:-}" || -z "${HEARTBEAT_TOKEN:-}" ]]; then
		return 0
	fi
	# The report carries the verdict and a human detail; a failure here is never fatal —
	# the state file still remembers this verdict, and the next minute's run reports again.
	curl -sS --max-time 10 -X POST "${HUB_HEARTBEAT_URL}" \
		-H "Authorization: Bearer ${HEARTBEAT_TOKEN}" \
		-H "Content-Type: application/json" \
		-d "{\"verdict\":\"${verdict}\",\"detail\":\"${detail}\"}" \
		> /dev/null 2>&1 || true
}

if [[ "${VERDICT}" == "up" ]]; then
	if [[ "${LAST_VERDICT}" != "up" && "${LAST_VERDICT}" != "none" ]]; then
		# A recovery is worth one alert: the story of the outage's end, after its beginning.
		send_alert "[anthers] outside check: RECOVERED" "anthers.org is answering again from the droplet's view (was: ${LAST_VERDICT})."
	fi
	write_state "up" "no"
	report_upstream "up" ""
elif [[ "${VERDICT}" == "degraded" ]]; then
	if [[ "${LAST_VERDICT}" != "degraded" && "${LAST_VERDICT}" != "none" ]]; then
		send_alert "[anthers] outside check: degraded" "${DETAIL}"
	fi
	write_state "degraded" "no"
	report_upstream "degraded" "${DETAIL}"
else
	if [[ "${LAST_VERDICT}" != "down" ]]; then
		send_alert "[anthers] outside check: DOWN" "${DETAIL}"
	fi
	write_state "down" "yes"
	report_upstream "down" "${DETAIL}"
fi

# ── The public status page, regenerated from this verdict ────────────────────────────
# Runs last so the page reflects the verdict just written (state file) and the hub's
# freshest answer. Its failure is never fatal and never alarms: the page going stale is
# surfaced by its own timestamp, and the heartbeat log catches the stderr.

if [[ -x "${HEARTBEAT_DIR}/status-page.sh" || -x "/opt/anthers-node/scripts/status-page.sh" ]]; then
	PAGE_SCRIPT="${HEARTBEAT_DIR}/status-page.sh"
	[[ -x "${PAGE_SCRIPT}" ]] || PAGE_SCRIPT="/opt/anthers-node/scripts/status-page.sh"
	"${PAGE_SCRIPT}" || echo "heartbeat: status page generation failed — page may be stale" >&2
else
	echo "heartbeat: status-page.sh not found — skip regenerating the public page" >&2
fi