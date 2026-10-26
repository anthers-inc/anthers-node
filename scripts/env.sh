# SPDX-License-Identifier: Apache-2.0
#
# Read one value out of the node's `pds.env` without executing it.
#
# 🚨 **Never `source` that file.** It is a Compose `env_file`, not a shell script: a value
# holding a space and angle brackets — `PDS_EMAIL_FROM_ADDRESS=Anthers <noreply@anthers.social>`
# — is perfectly valid there and a redirect-plus-syntax error to bash, and a syntax error in a
# sourced file kills the shell that sourced it. That is how the hourly key-and-blob backup died
# for forty-seven days after mail was configured: it sourced the file, aborted on that line, and
# the cron log filled with the same error while nothing was copied.
#
# ⚠️ **The caller must set `ENV_FILE`.** Values are returned verbatim, so a caller that needs one
# passed to a container still passes it explicitly (`-e KEY="${value}"`); nothing is exported.
read_env() {
	sed -n "s/^$1=//p" "${ENV_FILE}" | tail -n 1
}
