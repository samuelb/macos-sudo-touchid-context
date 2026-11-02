#!/bin/bash
# Shows the active sudo_local lines, whether the installed module matches the
# one built next to this script, and whether only root can replace it.
# Run by `just status` and `pam-tid-context status`. Changes nothing.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$root/scripts/lib.sh"

hash() { if [[ -f "$1" ]]; then shasum -a 256 "$1" | cut -c1-16; else echo none; fi; }

echo "sudo_local (active lines):"
grep -v '^[[:space:]]*#' "$sudo_local" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
echo "installed: $(hash "$dest") ($dest)"
echo "built:     $(hash "$root/build/$module")"
if [[ -e "$dest" ]]; then
    if why="$(secure_path "$dest")"; then echo "path:      only root can replace it"; else echo "path:      NOT SAFE: $why"; fi
fi
if [[ -e "$legacy_dest" ]]; then echo "old copy:  $legacy_dest (no longer used; remove it)"; fi
