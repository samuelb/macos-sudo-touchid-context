#!/bin/bash
# Lays out a built checkout for a package, such as the Homebrew formula:
#
#   scripts/package.sh <dir>
#
# <dir>/scripts gets the install, uninstall and status scripts and the
# pam-tid-context command, <dir>/build the module and the libpam probe. That
# is the layout of a checkout, so the scripts find each other the same way.
# Nothing in <dir> is loaded by sudo: `pam-tid-context install` copies the
# module to the root-owned /usr/local/pam_tid_context first.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="${1:?usage: scripts/package.sh <dir>}"

[[ -f "$root/build/pam_tid_context.so" && -x "$root/build/probe_load" ]] || {
    echo "package: run 'just build' first" >&2
    exit 1
}

mkdir -p "$dir/scripts" "$dir/build"
install -m 0644 "$root/scripts/lib.sh" "$dir/scripts/"
install -m 0755 "$root/scripts/install.sh" "$root/scripts/uninstall.sh" "$root/scripts/status.sh" "$dir/scripts/"
install -m 0755 "$root/scripts/pam-tid-context.sh" "$dir/scripts/pam-tid-context"
install -m 0755 "$root/build/pam_tid_context.so" "$root/build/probe_load" "$dir/build/"
