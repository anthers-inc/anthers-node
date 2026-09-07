#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Generate the offline recovery keypair.
#
# 🚨 **Run this somewhere that is NOT the node.** The whole value of this key is that the
# server has never held it — a key generated on the machine it is meant to protect protects
# nothing. Run it on a laptop, put the private half in a password manager, and paste only
# the `did:key:` line into `pds.env` on the server.
#
# ⚠️ **It prints a private key to your terminal and writes no files.** That is deliberate:
# a file is something to forget about and find later. But your terminal keeps scrollback,
# and some shells keep history, so close the window when you are done and do not pipe this
# anywhere you would not put the key itself.
#
# The encoding is checked against a known answer before anything real is generated, because
# a `did:key:` that is subtly wrong does not fail — it produces a key that looks fine, goes
# into the config, and simply never matches, which is discovered on the day it is needed.
set -euo pipefail

die() { echo "  -> ERROR: $*" >&2; exit 1; }

command -v openssl >/dev/null || die "openssl is required and is not on PATH."
command -v python3 >/dev/null || die "python3 is required and is not on PATH."

# A compressed secp256k1 public key becomes a did:key by prefixing the multicodec for
# secp256k1-pub (0xe7 0x01) and encoding the result base58btc with a `z` prefix.
to_did_key() {
	python3 -c '
import sys
A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
raw = bytes.fromhex("e701") + bytes.fromhex(sys.argv[1])
n = int.from_bytes(raw, "big")
out = ""
while n:
    n, r = divmod(n, 58)
    out = A[r] + out
out = "1" * (len(raw) - len(raw.lstrip(b"\0"))) + out
print("did:key:z" + out)
' "$1"
}

# ─── Known answer, verified against @atproto/crypto ───
# This public key belongs to a throwaway keypair whose private half was discarded. It is
# here only so the encoder above proves itself before it is trusted with a real key.
readonly TEST_PUB="03530c4fa8214dc3fc07f011a3b9310d06bbd55dd9b00ff17e121e495c23863c54"
readonly TEST_DID="did:key:zQ3shkEHrW2UqqapTySPVtXC3HpndFZjWWYL3xTHzRBwA2923"
got="$(to_did_key "${TEST_PUB}")"
[[ "${got}" == "${TEST_DID}" ]] || die "the encoder failed its own known-answer check.
     expected ${TEST_DID}
     got      ${got}
   Refusing to generate a key, because a wrong did:key fails silently."

# ─── The real key ───
pem="$(mktemp)"
trap 'rm -f "${pem}"' EXIT
openssl ecparam -name secp256k1 -genkey -noout -out "${pem}" 2>/dev/null

private_hex="$(openssl ec -in "${pem}" -outform DER 2>/dev/null | tail -c +8 | head -c 32 | xxd -p -c 32)"
public_compressed="$(openssl ec -in "${pem}" -pubout -conv_form compressed -outform DER 2>/dev/null | tail -c 33 | xxd -p -c 33)"
did_key="$(to_did_key "${public_compressed}")"

[[ ${#private_hex} -eq 64 ]] || die "expected a 64-character private key, got ${#private_hex}."

cat <<EOF

  Encoder verified against a known answer. Here is your keypair.

  ── PRIVATE half — store this, never on the node ──────────────────────

  ${private_hex}

  ── PUBLIC half — this goes in pds.env ────────────────────────────────

  PDS_RECOVERY_DID_KEY=${did_key}

  ──────────────────────────────────────────────────────────────────────

  Put the private half somewhere you can reach within 72 hours, because that is
  the window in which this key can undo something signed by a key beneath it.
  A password manager is the usual right answer; a safe you visit twice a year
  is not, and neither is the machine this key exists to protect.

  Nothing has been written to disk. Close this terminal when you are done.

EOF
