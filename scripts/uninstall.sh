#!/bin/bash
# Switches /etc/pam.d/sudo_local back to Apple's pam_tid.so, then removes the module.
#
# Order matters: deleting the module while sudo_local still names it locks sudo
# out ("unable to initialize PAM"). The line goes first, the file second.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$root/scripts/lib.sh"
probe="$root/build/probe_load"

die() { echo "uninstall: $*" >&2; exit 1; }

[[ -x "$probe" ]] || die "run 'just build' first (the probe gates each step)"

if [[ -f "$sudo_local" ]] && grep -q "pam_tid_context\.so" "$sudo_local"; then
    backup="$sudo_local.bak-$(date +%Y%m%d-%H%M%S)"
    sudo cp -p "$sudo_local" "$backup"
    echo "backup: $backup"
    new="$(mktemp)"
    trap 'rm -f "$new"' EXIT
    # Drop our line; re-enable the stock Touch ID line we commented out on install.
    awk '
        /pam_tid_context\.so/ && !/^[[:space:]]*#/ { next }
        /^#auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so/ && !restored { sub(/^#/, ""); restored = 1 }
        { print }
    ' "$sudo_local" > "$new"
    sudo install -o root -g wheel -m 444 "$new" "$sudo_local"
    if ! "$probe" "$sudo_local"; then
        sudo cp -p "$backup" "$sudo_local"
        die "rewritten sudo_local rejected; restored $backup, module left in place"
    fi
fi

if grep -v '^[[:space:]]*#' "$sudo_local" 2>/dev/null | grep -q 'pam_tid_context\.so'; then
    die "sudo_local still references the module; not removing it"
fi

if why="$(secure_path "$dest_dir")"; then
    sudo rm -f "$dest"
    sudo rmdir "$dest_dir" 2>/dev/null || true
    echo "Removed $dest."
else
    echo "Not removing $dest as root: $why. Remove it by hand."
fi
if [[ -e "$legacy_dest" ]]; then
    # Not deleted here: its directory may be user-writable, and a root rm in a
    # directory the user controls can be pointed at another file.
    echo "An older copy at $legacy_dest is no longer used; remove it: sudo rm $legacy_dest"
fi
echo "Active sudo_local lines:"
grep -v '^[[:space:]]*#' "$sudo_local" 2>/dev/null | sed 's/^/    /' || true
