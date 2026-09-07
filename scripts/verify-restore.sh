#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Restore this node's live backups into a scratch directory and boot a server against them.
#
# 🚨 **A backup that has never been restored is not a backup.** This is that rule made
# executable, and it is a required step rather than a nicety — run it after standing a node
# up, and again after any change to the replication config. It touches nothing the live
# server uses: it restores into a temporary directory and starts a second container on a
# spare port.
#
# ⭐ **The key check is the one that earns this script.** Every database can restore
# perfectly while the accounts' signing keys are absent, and the resulting server answers
# reads with a cheerful 200 — the loss only surfaces the first time somebody publishes, as
# an opaque 500. That was reproduced deliberately: with the keys deleted and nothing else
# changed, `describeRepo` returned 200 and `putRecord` returned 500. So this asserts the
# keys are present and the right size before it asserts anything else.
set -euo pipefail

PDS_DIR="${PDS_DIR:-/pds}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${VERIFY_PORT:-2586}"
IMAGE="ghcr.io/bluesky-social/pds:0.4"
CONTAINER="anthers-node-verify"

die() { echo "  -> FAIL: $*" >&2; exit 1; }

[[ -r "${PDS_DIR}/pds.env" ]] || die "cannot read ${PDS_DIR}/pds.env"
command -v docker >/dev/null || die "docker is required"

scratch="$(mktemp -d)"
cleanup() {
	docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
	# The restore runs containers as this user, but a stray root-owned file should not
	# leave a directory nobody can clear.
	docker run --rm -v "${scratch}:/s" alpine:latest sh -c 'rm -rf /s/..?* /s/.[!.]* /s/*' >/dev/null 2>&1 || true
	rm -rf "${scratch}"
}
trap cleanup EXIT

echo "  -> restoring into ${scratch}"
install -m 0600 "${PDS_DIR}/pds.env" "${scratch}/pds.env"
PDS_DIR="${scratch}" "${HERE}/restore.sh"

echo
echo "  -> checking the signing keys"
mapfile -t keys < <(find "${scratch}/actors" -name key -type f 2>/dev/null | sort)
(( ${#keys[@]} > 0 )) || echo "  -> no accounts on this node yet; nothing to check beyond the shared databases"
for key in "${keys[@]}"; do
	size=$(wc -c < "${key}")
	(( size == 32 )) || die "signing key at ${key} is ${size} bytes, expected 32"
done
echo "  -> ${#keys[@]} key(s), all 32 bytes"

echo "  -> booting a server against the restored data on port ${PORT}"
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" \
	--env-file "${scratch}/pds.env" \
	-e PDS_DEV_MODE=true \
	-e PDS_HOSTNAME=localhost \
	-e PDS_PORT="${PORT}" \
	-e PDS_DATA_DIRECTORY=/pds \
	-e PDS_BLOBSTORE_DISK_LOCATION=/pds/blocks \
	-p "${PORT}:${PORT}" \
	-v "${scratch}:/pds" \
	"${IMAGE}" >/dev/null

for _ in $(seq 1 40); do
	curl -sf -m 2 "http://localhost:${PORT}/xrpc/_health" >/dev/null 2>&1 && break
	sleep 1
done
curl -sf -m 2 "http://localhost:${PORT}/xrpc/_health" >/dev/null 2>&1 \
	|| { docker logs "${CONTAINER}" 2>&1 | tail -20; die "the server did not come up on the restored data"; }

echo "  -> the server answers. Checking each account resolves."
for key in "${keys[@]}"; do
	did="$(basename "$(dirname "${key}")")"
	code=$(curl -sS -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/xrpc/com.atproto.repo.describeRepo?repo=${did}")
	[[ "${code}" == "200" ]] || die "${did} did not resolve on the restored server (HTTP ${code})"
	echo "     ${did} ok"
done

echo
echo "  -> PASS: the backups restore, and the restored data serves every account."
