#!/bin/bash
# Says whether sudo uses the module, whether the one built next to this script
# differs from the installed one, and what to run next; then shows the active
# sudo_local lines, both hashes, and whether only root can replace the module.
# Run by `just status` and `pam-tid-context status`. Changes nothing.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$root/scripts/lib.sh"

hash() { if [[ -f "$1" ]]; then shasum -a 256 "$1" | cut -c1-16; else echo none; fi; }

# A package (scripts/package.sh) installs the command as scripts/pam-tid-context;
# a checkout runs the just recipes. A Homebrew keg lives under Cellar.
cmd=just
[[ -x "$root/scripts/pam-tid-context" ]] && cmd=pam-tid-context
brew=""
[[ "$root" == */Cellar/pam-tid-context/* ]] && brew=yes

status_summary "$sudo_local" "$dest" "$root/build/$module" "$cmd" "$brew"
echo
echo "sudo_local (active lines):"
grep -v '^[[:space:]]*#' "$sudo_local" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
echo "installed: $(hash "$dest") ($dest)"
echo "built:     $(hash "$root/build/$module")"
if [[ -e "$dest" ]]; then
    if why="$(secure_path "$dest")"; then echo "path:      only root can replace it"; else echo "path:      NOT SAFE: $why"; fi
fi
if [[ -e "$legacy_dest" ]]; then echo "old copy:  $legacy_dest (no longer used; remove it)"; fi
