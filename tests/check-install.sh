#!/bin/bash
# Checks the install helpers in scripts/lib.sh against temporary files only:
# nothing here touches /etc/pam.d or needs root.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$repo/scripts/lib.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n     %s\n' "$1" "$2"; fail=1; }

expect_secure() {  # expect_secure <label> <path>
    local why
    if why="$(secure_path "$2")"; then ok "$1"; else bad "$1" "secure_path $2 refused: $why"; fi
}
expect_insecure() {  # expect_insecure <label> <path> <substring of the reason>
    local why
    if why="$(secure_path "$2")"; then
        bad "$1" "secure_path $2 accepted it"
    elif [[ "$why" == *"$3"* ]]; then
        ok "$1"
    else
        bad "$1" "want reason containing '$3', got: $why"
    fi
}

# --- secure_path: who can replace the module sudo loads as root
expect_secure   "root-owned system directory"            /usr/bin
expect_secure   "missing components are created by root" /usr/bin/pam_tid_context_missing/x.so
expect_insecure "user-owned directory refused"           "$HOME"                  "not root"
expect_insecure "user-owned parent refused"              "$HOME/pam/x.so"         "not root"
expect_insecure "symlink in the path refused"            /etc/pam.d               "symlink"
expect_insecure "relative path refused"                  usr/local                "not an absolute path"
expect_insecure "group-writable directory refused"       /Applications/x.so       "writable by group or others"
expect_insecure "world-writable directory refused"       /private/tmp/x.so        "writable by group or others"

exit "$fail"
