#!/bin/bash
# Switches /etc/pam.d/sudo_local back to Apple's pam_tid.so, then removes the module.
#
# Order matters: deleting the module while sudo_local still names it locks sudo
# out ("unable to initialize PAM"). The line goes first, the file second, both
# in one root process (see "Privileged steps" in scripts/lib.sh).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$root/scripts/lib.sh"
probe="$root/build/probe_load"

die() { echo "uninstall: $*" >&2; exit 1; }

[[ -x "$probe" ]] || die "run 'just build' first (the probe gates each step)"
[[ -t 0 ]] || die "run it from a terminal: it shows the changes and asks before making them"

echo "1/3 staging the probe and the rewritten sudo_local as root (sudo)"
new="$(mktemp)"
stage=""
cleanup() {
    rm -f "$new"
    if [[ -n "$stage" ]]; then /usr/bin/sudo /bin/rm -rf "$stage"; fi
}
trap cleanup EXIT
stage="$(make_stage "$probe")"
if [[ -f "$sudo_local" ]] && grep -q "pam_tid_context\.so" "$sudo_local"; then
    # Drop our line; re-enable the stock Touch ID line we commented out on install.
    awk '
        /pam_tid_context\.so/ && !/^[[:space:]]*#/ { next }
        /^#auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so/ && !restored { sub(/^#/, ""); restored = 1 }
        { print }
    ' "$sudo_local" > "$new"
    stage_file "$new" "$stage/sudo_local"
fi

echo "2/3 review"
if [[ -f "$stage/sudo_local" ]]; then
    echo "    $sudo_local:"
    diff -u "$sudo_local" "$stage/sudo_local" | sed 's/^/        /' || true
else
    echo "    $sudo_local: no change (it does not use the module)"
fi
echo "    then remove: $dest"
confirm "Make these changes?" || die "cancelled; nothing changed"

echo "3/3 uninstalling: check, write sudo_local, check again, then remove the module (sudo)"
run_as_root root_uninstall "$stage" "$dest" "$sudo_local" || die "stopped (see above)"

if [[ -e "$legacy_dest" ]]; then
    # Not deleted here: its directory may be user-writable, and a root rm in a
    # directory the user controls can be pointed at another file.
    echo "An older copy at $legacy_dest is no longer used; remove it: sudo rm $legacy_dest"
fi
echo "Done. Active sudo_local lines:"
grep -v '^[[:space:]]*#' "$sudo_local" 2>/dev/null | sed 's/^/    /' || true
