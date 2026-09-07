#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Rebuild a node's data directory from object storage onto an empty machine.
#
# ⭐ **The key backup is also the manifest, and that is what makes this possible at all.**
# Directory replication is asymmetric: Litestream discovers new databases by itself while
# replicating, and offers nothing that enumerates them while restoring — `restore` takes one
# database at a time, and on an empty machine nobody knows which accounts existed. The
# `actors/<shard>/<did>/key` files carry that list, so they come back first and the DIDs in
# them drive everything after.
#
# ⚠️ **Each database is restored through a generated single-database config, which looks
# indirect and is the only thing that works.** `litestream restore` reads its replica
# settings from a config file or a replica URL, and a `dir`-mode config answers
# `database not found in config` for any individual path — while the URL form has nowhere to
# put a custom endpoint. A small config per database carries the endpoint, region and
# credentials that an S3-compatible store needs.
#
# 🚨 **This does not restore `pds.env`, and it cannot.** The backup is written using
# credentials that live in that file, so a copy of it inside the backup would be a copy you
# could not reach without already having it. It also holds the rotation key, which cannot be
# regenerated. The off-machine copy `setup.sh` tells you to take is the only source, and this
# script refuses to start without it.
set -euo pipefail

PDS_DIR="${PDS_DIR:-/pds}"
ENV_FILE="${PDS_DIR}/pds.env"
LITESTREAM_IMAGE="litestream/litestream:0.5.17"
AWS_IMAGE="amazon/aws-cli:latest"

die() { echo "  -> ERROR: $*" >&2; exit 1; }

[[ -r "${ENV_FILE}" ]] || die "no ${ENV_FILE}. Restore your off-machine copy of it first — it holds the rotation key, and nothing here can rebuild that."
set -a; . "${ENV_FILE}"; set +a

: "${NODE_BACKUP_BUCKET:?not set in ${ENV_FILE}}"
: "${NODE_BACKUP_ENDPOINT:?not set in ${ENV_FILE}}"
: "${NODE_BACKUP_ACCESS_KEY_ID:?not set in ${ENV_FILE}}"
: "${NODE_BACKUP_SECRET_ACCESS_KEY:?not set in ${ENV_FILE}}"

prefix="${NODE_BACKUP_PREFIX:-pds}"
keys_prefix="${prefix}-keys"
region="${NODE_BACKUP_REGION:-auto}"

[[ -e "${PDS_DIR}/account.sqlite" ]] && die "${PDS_DIR}/account.sqlite exists. Restore onto an empty data directory, never over a live one."

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

aws_s3() {
	docker run --rm --user "$(id -u):$(id -g)" \
		-e AWS_ACCESS_KEY_ID="${NODE_BACKUP_ACCESS_KEY_ID}" \
		-e AWS_SECRET_ACCESS_KEY="${NODE_BACKUP_SECRET_ACCESS_KEY}" \
		-e AWS_DEFAULT_REGION="${region}" \
		-v "${PDS_DIR}:${PDS_DIR}" \
		"${AWS_IMAGE}" \
		--endpoint-url "${NODE_BACKUP_ENDPOINT}" \
		s3 "$@"
}

# One database, named by its path relative to the data directory.
restore_db() {
	local rel="$1"
	mkdir -p "${PDS_DIR}/$(dirname "${rel}")"
	cat > "${work}/one.yml" <<-EOF
		dbs:
		  - path: ${PDS_DIR}/${rel}
		    replica:
		      type: s3
		      bucket: ${NODE_BACKUP_BUCKET}
		      path: ${prefix}/${rel}
		      endpoint: ${NODE_BACKUP_ENDPOINT}
		      region: ${region}
		      access-key-id: ${NODE_BACKUP_ACCESS_KEY_ID}
		      secret-access-key: ${NODE_BACKUP_SECRET_ACCESS_KEY}
	EOF
	docker run --rm --user "$(id -u):$(id -g)" \
		-v "${PDS_DIR}:${PDS_DIR}" \
		-v "${work}/one.yml:/etc/litestream.yml:ro" \
		"${LITESTREAM_IMAGE}" \
		restore -config /etc/litestream.yml "${PDS_DIR}/${rel}"
}

echo "  -> restoring account signing keys, which are also the list of accounts"
mkdir -p "${PDS_DIR}"
aws_s3 cp "s3://${NODE_BACKUP_BUCKET}/${keys_prefix}/actors" "${PDS_DIR}/actors" --recursive

mapfile -t keys < <(find "${PDS_DIR}/actors" -name key -type f 2>/dev/null | sort)
echo "  -> ${#keys[@]} account(s) named in the backup"

echo "  -> restoring the three shared databases"
for db in account.sqlite sequencer.sqlite did_cache.sqlite; do
	echo "     ${db}"
	restore_db "${db}"
done

echo "  -> restoring each account's repository"
for key in "${keys[@]}"; do
	dir="$(dirname "${key}")"
	echo "     $(basename "${dir}")"
	restore_db "${dir#"${PDS_DIR}/"}/store.sqlite"
done

echo "  -> restoring blobs"
blobs="${PDS_BLOBSTORE_DISK_LOCATION:-${PDS_DIR}/blocks}"
mkdir -p "${blobs}"
aws_s3 sync "s3://${NODE_BACKUP_BUCKET}/${prefix}/blocks" "${blobs}" || true

# 🚨 The check that catches the failure this whole script is shaped around, and it is worth
# failing loudly here because the server will not. A restore that brought back every database
# and no keys serves reads perfectly — `describeRepo` answers 200 — and fails the first
# attempt to publish with an opaque 500, which is the worst possible place to discover it.
missing=0
for key in "${keys[@]}"; do
	[[ -s "${key}" ]] || { echo "  -> MISSING signing key at ${key}" >&2; missing=1; }
	store="$(dirname "${key}")/store.sqlite"
	[[ -s "${store}" ]] || { echo "  -> MISSING repository at ${store}" >&2; missing=1; }
done
(( missing == 0 )) || die "the restore is incomplete. Do not start the server on it."

echo "  -> restored. Run scripts/verify-restore.sh before trusting it."
