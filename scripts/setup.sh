#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Lay out /pds and generate the secrets a node needs, once.
#
# 🚨 **Refuses to run over an existing installation.** The three generated values below
# cannot be regenerated: the rotation key signs this server's identity documents, and a
# second one does not replace the first, it simply cannot speak for anything the first
# created. Overwriting them is the one mistake here with no recovery, so the guard is a
# refusal rather than a prompt.
set -euo pipefail

PDS_DIR="${PDS_DIR:-/pds}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "  -> ERROR: $*" >&2; exit 1; }

[[ -e "${PDS_DIR}/pds.env" ]] && die "${PDS_DIR}/pds.env exists. Refusing to overwrite secrets that cannot be regenerated."

command -v openssl >/dev/null || die "openssl is required and is not on PATH."
command -v docker  >/dev/null || die "docker is required and is not on PATH."

hostname="${1:-}"
[[ -n "${hostname}" ]] || die "usage: $0 <hostname>   e.g. $0 node.example.org"

echo "  -> creating ${PDS_DIR}"
mkdir -p "${PDS_DIR}"/{blocks,caddy/data,caddy/etc/caddy}

echo "  -> installing the Caddyfile and the replication config"
install -m 0644 "${HERE}/caddy/Caddyfile" "${PDS_DIR}/caddy/etc/caddy/Caddyfile"
install -m 0644 "${HERE}/litestream.yml"  "${PDS_DIR}/litestream.yml"

echo "  -> generating secrets"
# Matching the upstream installer's generation exactly: 16 random bytes as hex for the two
# symmetric secrets, and a secp256k1 private key for the rotation key.
jwt_secret=$(openssl rand --hex 16)
admin_password=$(openssl rand --hex 16)
rotation_key=$(openssl ecparam --name secp256k1 --genkey --noout --outform DER | tail --bytes=+8 | head --bytes=32 | xxd --plain --cols 32)

sed \
	-e "s|^PDS_HOSTNAME=.*|PDS_HOSTNAME=${hostname}|" \
	-e "s|^PDS_JWT_SECRET=.*|PDS_JWT_SECRET=${jwt_secret}|" \
	-e "s|^PDS_ADMIN_PASSWORD=.*|PDS_ADMIN_PASSWORD=${admin_password}|" \
	-e "s|^PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=.*|PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=${rotation_key}|" \
	"${HERE}/pds.env.example" > "${PDS_DIR}/pds.env"

# The rotation key is in here. Nobody but root has any business reading it.
chmod 0600 "${PDS_DIR}/pds.env"

cat <<EOF

  -> ${PDS_DIR} is laid out and ${PDS_DIR}/pds.env holds freshly generated secrets.

Before starting anything, three things are still yours to do:

  1. Fill in the NODE_BACKUP_* block in ${PDS_DIR}/pds.env. A node holds the only copy of
     a repository, so a node without a backup target is a node with a countdown on it.

  2. Point DNS at this machine: an A record for ${hostname}, and a wildcard A record for
     *.${hostname} so that handles issued here can get certificates.

  3. Take a copy of ${PDS_DIR}/pds.env somewhere off this machine. The rotation key in it
     cannot be regenerated, and the backups do not contain it — they are written using
     credentials that live in this same file, so a backup that could restore it would be a
     backup you could not reach without it.

If this node will hold accounts for anybody but you, also set PDS_RECOVERY_DID_KEY — a
second rotation key, generated somewhere other than here, whose private half never touches
this machine. It is what you use if the key in step 3 is ever stolen, and it is deliberately
not generated for you. See "The keys, and who holds them" in the README.

Then:  docker compose --profile unattended up -d
EOF
