#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The public status page at status.anthers.org — generated here, on the droplet.
#
# 🚨 **Why the page lives here and not on the hub.** The hub's own /status page is served
# by the same App Platform deployment it reports on, so the reader checking whether the
# platform is down needs the platform to be up to find out. This page answers from a
# failure domain App Platform does not share: the same droplet the outside heartbeat runs
# on, whose verdict about the hub exists whether or not the hub can say anything. When the
# hub is up, the page renders the hub's full component answer; when it is down, the page
# still answers — with the droplet's own "the site is not answering" verdict in the row
# that matters. This is the design the copy on the hub's page apologizes for; the answer
# was to move the page rather than to soften the sentence.
#
# **The mechanism is static regeneration, not a live server.** The heartbeat's cron (every
# minute) runs this script after its check; it writes one self-contained index.html from
# the hub's last answer (.last-body) and its own verdict state. No listener, no proxy, no
# second runtime on a 1 GB box: if this script dies, the page goes stale beside the state
# file it is generated from — and staleness is stamped on the page itself, so a stale page
# reads as one rather than claiming freshness.
#
# ⚠️ **The file lives under /pds/status/ and Caddy serves it** (see the Caddyfile's
# status.anthers.org site). /pds is root-owned like everything else on this box; the
# generated file is world-readable on purpose — it is the public page — while the
# directory it is written through keeps the heartbeat's 0700 discipline for the state
# and env files beside it.
#
# Installation: called by heartbeat-check.sh after its check (same cron minute), so the
# page is exactly as fresh as the outside verdict. Needs STATUS_PAGE_DIR to exist and be
# writable; skips loudly in stderr if not, which the heartbeat log catches.

set -euo pipefail

HEARTBEAT_DIR="${HEARTBEAT_DIR:-/pds/heartbeat}"
# shellcheck source=/dev/null
source "${HEARTBEAT_DIR}/heartbeat.env"

STATUS_PAGE_DIR="${STATUS_PAGE_DIR:-/pds/status}"
HUB_STATUS_URL="${HUB_STATUS_URL:-https://anthers.org/api/status}"
PAGE_URL="${PAGE_URL:-https://status.anthers.org}"
# Own default, deliberately not inherited from heartbeat-check.sh's: that script sets
# TIMEOUT_SECS as a shell variable and exports nothing, so a child run under `set -u`
# reads unbound here. This is the 2026-10-08 first-live-run lesson.
TIMEOUT_SECS="${TIMEOUT_SECS:-10}"

# ── What the page is generated from ─────────────────────────────────────────────────

# The hub's whole component answer, when the hub answered: the heartbeat's .last-body
# carries /health's JSON (the check the verdict comes from), which names per-component
# states but is the *hub's* shape. Prefer /api/status — the composed public answer —
# fetched on this script's own connection; on failure fall back to .last-body (same
# minute's /health), and on that failing to nothing.
SNAPSHOT=""
SNAPSHOT_SOURCE=""
HTTP_CODE=""
HTTP_CODE=$(curl -sS --max-time "${TIMEOUT_SECS}" -o "${HEARTBEAT_DIR}/.last-status.json" -w "%{http_code}" \
	"${HUB_STATUS_URL}" 2>/dev/null) || HTTP_CODE="000"
if [[ "${HTTP_CODE}" == "200" ]]; then
	SNAPSHOT=$(cat "${HEARTBEAT_DIR}/.last-status.json" 2>/dev/null || echo "")
	SNAPSHOT_SOURCE="hub"
fi

# ── Tiny HTML escaping — the page renders hub-provided sentences verbatim ───────────

esc() {
	local s="$1"
	printf '%s' "${s//&/&amp;}" | sed -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# ── Page assembly ────────────────────────────────────────────────────────────────────

GEN_STAMP="$(date -u '+%Y-%m-%d %H:%M UTC')"

# The droplet's own verdict about the hub, from the state file the heartbeat just wrote
# (this script runs as a child of its cron, so nothing is inherited — the file IS the
# handoff). Mapped to the page vocabulary; `none` (first run) or a missing file reads
# unknown, the honest answer.
LAST_VERDICT="none"
if [[ -r "${HEARTBEAT_DIR}/heartbeat.state" ]]; then
	# shellcheck source=/dev/null
	source "${HEARTBEAT_DIR}/heartbeat.state" || true
fi
VERDICT_FOR_PAGE="unknown"
case "${LAST_VERDICT}" in
	up) VERDICT_FOR_PAGE="operational" ;;
	down) VERDICT_FOR_PAGE="down" ;;
	degraded) VERDICT_FOR_PAGE="degraded" ;;
esac

# The rows: from the hub's answer when we have one; otherwise one row saying what this
# machine itself observed — which is the case the whole arrangement exists for.
ROWS=""
HEADLINE="All systems operational"

if [[ -n "${SNAPSHOT}" ]]; then
	# Parse the hub's answer with python3 (present on the droplet), never regex over JSON.
	# OUTSIDE_VERDICT passes this run's own verdict in — the droplet's check of the hub IS
	# the outside view, and on this page it is rendered from the source rather than echoed.
	ROWS=$(OUTSIDE_VERDICT="${VERDICT_FOR_PAGE}" python3 - "$SNAPSHOT" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone

try:
	d = json.loads(sys.argv[1])
except Exception:
	print("PAGE_ERROR"); sys.exit(0)

LABEL = {"operational": "Operational", "degraded": "Degraded", "down": "Down", "unknown": "Unknown"}

def esc(s):
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

def dur(iso, now):
	try:
		t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
	except Exception:
		return None
	s = int((now - t).total_seconds())
	if s < 90: return f"{s} seconds"
	if s < 5400: return f"{max(1, s // 60)} minutes"
	if s < 172800: return f"{s // 3600} hours"
	return f"{s // 86400} days"

now = datetime.now(timezone.utc)
rows = []
# 🚨 The outside row renders THIS machine's verdict (heartbeat.state via OUTSIDE_VERDICT),
# never the hub's echo of it — the hub's "Outside view" component is what the hub believes
# about this check, which on this page is circular. The env is the handoff from bash.
outside = os.environ.get("OUTSIDE_VERDICT", "unknown")
rows.append(("<strong>Checked from outside</strong> — by this server, which is outside Anthers' hosting platform",
	outside,
	"" ,
	None, now))
ext = d.get("external") or {}
for c in d.get("components", []):
	if c.get("name") == "Outside view":
		continue  # this page renders the droplet's own verdict above, not the hub's echo
	rows.append((esc(c.get("name", "?")), c.get("state", "unknown"), c.get("detail") or "", c.get("since"), now))

for name, state, detail, since, n in rows:
	lbl = LABEL.get(state, "Unknown")
	line = ""
	if detail: line += esc(detail)
	if since and state != "operational":
		d1 = dur(since, n)
		if d1: line += (f" " if line else "") + f"Continuing for about {d1}."
	badge = {"operational": "ok", "degraded": "warn", "down": "err"}.get(state, "unknown")
	print(f'<div class="row {badge}"><div class="rowhead"><span class="name">{name}</span><span class="pill {badge}">{lbl}</span></div><p>{line}</p></div>')

overall = d.get("state", "unknown")
print(f'<!--OVERALL:{overall}-->')
PYEOF
	) || ROWS="PAGE_ERROR"
	if [[ "${ROWS}" == "PAGE_ERROR" || -z "${ROWS}" ]]; then
		ROWS=""
		SNAPSHOT_SOURCE=""
	else
		OVERALL=$(printf '%s' "${ROWS}" | grep -o '<!--OVERALL:[a-z-]*-->' | head -1 | sed 's/<!--OVERALL:\([a-z-]*\)-->/\1/' || true)
		ROWS=$(printf '%s' "${ROWS}" | sed 's/<!--OVERALL:[a-z-]*-->//')
		case "${OVERALL}" in
			operational) HEADLINE="All systems operational" ;;
			degraded) HEADLINE="Some systems degraded" ;;
			down) HEADLINE="Service disruption" ;;
			*) HEADLINE="Current status" ;;
		esac
	fi
fi

if [[ -z "${SNAPSHOT_SOURCE}" ]]; then
	# The hub did not answer /api/status — the case the whole arrangement exists for.
	# The page renders the droplet's own row and nothing else: honest about knowing less,
	# never pretending the hub told it everything is fine. The headline follows the
	# droplet's verdict, not hope.
	local_verdict_row() {
		local cls pill detail
		case "${LAST_VERDICT}" in
			up)
				cls="ok"; pill="Operational"
				detail="anthers.org answered the outside check. Its own component detail is not reachable while this page cannot reach it either — reload in a moment."
				;;
			down)
				cls="err"; pill="Down"; detail="${OUTAGE_DETAIL}"
				;;
			degraded)
				cls="warn"; pill="Degraded"; detail="${OUTAGE_DETAIL}"
				;;
			*)
				cls="unknown"; pill="Unknown"
				detail="The outside check has not reported a verdict yet."
				;;
		esac
		printf '<div class="row %s"><div class="rowhead"><span class="name"><strong>Checked from outside</strong> — by this server, which is outside Anthers'"'"' hosting platform</span><span class="pill %s">%s</span></div><p>%s</p></div>' \
			"${cls}" "${cls}" "${pill}" "$(esc "${detail}")"
	}
	OUTAGE_DETAIL="anthers.org did not answer this outside check. The site's own components cannot be read while it does not answer; the check emails Anthers directly, and this page keeps answering."
	case "${LAST_VERDICT}" in
		down) HEADLINE="Service disruption" ;;
		degraded) HEADLINE="Some systems degraded" ;;
		up) HEADLINE="Site answering; detail unavailable" ;;
		*) HEADLINE="Status cannot be checked yet" ;;
	esac
	ROWS="$(local_verdict_row)"
fi

# ── Write the page ───────────────────────────────────────────────────────────────────

write_page() {
	# /pds/status is root-owned on the droplet; the stage-and-sudo-mv form works there,
	# where this script runs under the anthers user's passwordless sudo. Where sudo is
	# unavailable (a plain directory, a developer's machine), the directory is written
	# directly — the page test runs everywhere, the sudo only where it must.
	local stage="${HEARTBEAT_DIR}/.status-index.next"
	printf '%s' "$1" > "${stage}"
	if sudo -n true 2>/dev/null; then
		sudo mv "${stage}" "${STATUS_PAGE_DIR}/index.html"
		sudo chmod 0644 "${STATUS_PAGE_DIR}/index.html"
	else
		mv "${stage}" "${STATUS_PAGE_DIR}/index.html"
	fi
}

read -r -d '' PAGE <<HTML || true
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Anthers status</title>
<meta name="robots" content="noindex">
<style>
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body { font-family: system-ui, -apple-system, sans-serif; margin: 0; background: #f7f5f0; color: #21301f; }
main { max-width: 44rem; margin: 0 auto; padding: 2.5rem 1.25rem 4rem; }
h1 { font-weight: 400; font-size: 2rem; margin: 0 0 .25rem; }
.brand { color: #2c6e49; font-size: .8rem; font-weight: 600; letter-spacing: .18em; text-transform: uppercase; margin: 0 0 1.5rem; }
.stamp { color: #6b7280; font-size: .85rem; margin: 0 0 2rem; }
.row { border: 1px solid rgba(0,0,0,.12); border-radius: .75rem; padding: 1rem 1.25rem; margin: 0 0 .75rem; }
.rowhead { display: flex; justify-content: space-between; align-items: baseline; gap: 1rem; flex-wrap: wrap; }
.name { font-weight: 600; }
.pill { font-size: .8rem; font-weight: 600; border-radius: 999px; padding: .2rem .75rem; white-space: nowrap; }
.row.ok { border-color: rgba(44,110,73,.35); } .row.ok .pill { background: rgba(44,110,73,.12); color: #2c6e49; }
.row.warn { border-color: rgba(180,131,32,.4); } .row.warn .pill { background: rgba(180,131,32,.14); color: #8a6414; }
.row.err { border-color: rgba(180,55,55,.4); } .row.err .pill { background: rgba(180,55,55,.12); color: #a32c2c; }
.pill.unknown { background: rgba(0,0,0,.06); color: #555; }
p { margin: .4rem 0 0; color: #4b5563; font-size: .92rem; }
.foot { color: #6b7280; font-size: .85rem; margin-top: 2rem; }
.foot a { color: #2c6e49; }
@media (prefers-color-scheme: dark) {
	body { background: #171d18; color: #e5e7dc; }
	.row { border-color: rgba(255,255,255,.14); }
	.row.ok { border-color: rgba(110,200,150,.3); } .row.ok .pill { background: rgba(110,200,150,.14); color: #7fd0a0; }
	.row.warn { border-color: rgba(230,190,90,.35); } .row.warn .pill { background: rgba(230,190,90,.15); color: #e6c46a; }
	.row.err { border-color: rgba(230,110,110,.35); } .row.err .pill { background: rgba(230,110,110,.14); color: #e88; }
	.pill.unknown { background: rgba(255,255,255,.08); color: #aaa; }
	p, .stamp, .foot { color: #a3a8a0; }
	.foot a { color: #7fd0a0; }
}
</style>
</head>
<body>
<main>
<p class="brand">Anthers</p>
<h1>$(esc "${HEADLINE}")</h1>
<p class="stamp">Answered fresh at $(esc "${GEN_STAMP}") — this page rebuilds every minute from a check that runs outside Anthers' hosting platform. Reload for the latest.</p>
${ROWS}
<div class="foot">This page is served from a machine separate from the one serving anthers.org, so it stays up when the site is down. Something not on this page? <a href="https://anthers.org/issues">Report an issue</a>.</div>
</main>
</body>
</html>
HTML

write_page "${PAGE}"
echo "status page written: ${STATUS_PAGE_DIR}/index.html (${SNAPSHOT_SOURCE:-outside-only}, headline: ${HEADLINE})"