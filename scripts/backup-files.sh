#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Back up everything Litestream cannot: the account signing keys, and the blobs.
#
# 🚨 **The keys are the reason this script exists, and they are easy to not notice.** Beside
# every account's `store.sqlite` is a 32-byte file called `key`, which is the key that
# account signs its repository with. Litestream replicates databases, so it will never carry
# it — and a restore that brings back every database without the keys produces repositories
# that can be read and never written to again. The failure is silent at restore time and
# only shows up the first time somebody tries to publish.
#
# ⚠️ **Blobs are here for the opposite reason.** They are large and immutable once written,
# so they want a sync that skips what it already has rather than write-ahead-log
# replication. They are also the only part of this that is genuinely big.
#
# Run it from cron. Hourly is generous for the keys, which change only when an account is
# created, and fine for blobs, which are additive.
set -euo pipefail

PDS_DIR="${PDS_DIR:-/pds}"
ENV_FILE="${PDS_DIR}/pds.env"

die() { echo "  -> ERROR: $*" >&2; exit 1; }

[[ -r "${ENV_FILE}" ]] || die "cannot read ${ENV_FILE}"
set -a; . "${ENV_FILE}"; set +a

: "${NODE_BACKUP_BUCKET:?not set in ${ENV_FILE}}"
: "${NODE_BACKUP_ENDPOINT:?not set in ${ENV_FILE}}"
: "${NODE_BACKUP_ACCESS_KEY_ID:?not set in ${ENV_FILE}}"
: "${NODE_BACKUP_SECRET_ACCESS_KEY:?not set in ${ENV_FILE}}"

prefix="${NODE_BACKUP_PREFIX:-pds}"
# 🚨 **The keys go under their OWN prefix, clear of the replication tree, and this is a
# correctness requirement rather than tidiness.** Litestream replicates a database to a
# *directory* named after it — `<prefix>/actors/<shard>/<did>/store.sqlite/…` — so keys
# written under `<prefix>/actors/` interleave with it, and restoring `actors/` recursively
# then drags down every replication segment and lands a directory exactly where the restored
# `store.sqlite` file has to go. Separate prefixes keep the manifest a manifest.
keys_prefix="${prefix}-keys"

# The AWS CLI in a container, so a node needs nothing installed but Docker.
aws_s3() {
	docker run --rm \
		-e AWS_ACCESS_KEY_ID="${NODE_BACKUP_ACCESS_KEY_ID}" \
		-e AWS_SECRET_ACCESS_KEY="${NODE_BACKUP_SECRET_ACCESS_KEY}" \
		-e AWS_DEFAULT_REGION="${NODE_BACKUP_REGION:-auto}" \
		-v "${PDS_DIR}:${PDS_DIR}:ro" \
		amazon/aws-cli:latest \
		--endpoint-url "${NODE_BACKUP_ENDPOINT}" \
		s3 "$@"
}

# ⭐ Copied in full every run rather than synced. The whole set is a few kilobytes even at
# thousands of accounts, and `sync` deletes on the destination when the source loses a file
# — which is the one behavior this data must never have.
if [[ -d "${PDS_DIR}/actors" ]]; then
	echo "  -> backing up account signing keys"
	aws_s3 cp "${PDS_DIR}/actors" "s3://${NODE_BACKUP_BUCKET}/${keys_prefix}/actors" \
		--recursive --exclude "*" --include "*/key"
	keys=$(find "${PDS_DIR}/actors" -name key -type f | wc -l)
	echo "  -> ${keys} key(s) backed up"
else
	echo "  -> no accounts on this server yet, so no keys to back up"
fi

blobs="${PDS_BLOBSTORE_DISK_LOCATION:-${PDS_DIR}/blocks}"
if [[ -d "${blobs}" ]]; then
	echo "  -> syncing blobs"
	aws_s3 sync "${blobs}" "s3://${NODE_BACKUP_BUCKET}/${prefix}/blocks"
fi

echo "  -> done"
