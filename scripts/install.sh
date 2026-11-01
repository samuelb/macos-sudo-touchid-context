#!/bin/bash
# Installs pam_tid_context.so and switches /etc/pam.d/sudo_local to it.
#
# A PAM module that fails to load makes sudo refuse every login ("unable to
# initialize PAM"), whatever its control flag. So the new sudo_local is checked
# with libpam before it is written and again in place, and rolled back at once
# if libpam rejects it, all in one root process (see "Privileged steps" in
# scripts/lib.sh). Keep a root shell open while running this anyway (see
# README, Recovery).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$root/scripts/lib.sh"
probe="$root/build/probe_load"

die() { echo "install: $*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "macOS only"
[[ -f "$root/build/$module" && -x "$probe" ]] || die "run 'just build' first"
[[ -t 0 ]] || die "run it from a terminal: it shows the changes and asks before making them"

echo "1/4 checking the built module and the install location"
"$probe" "$root/build/$module" || die "built module rejected by libpam; nothing changed"
# Anyone who can write to a directory above the module can swap it for their
# own and get root from the next sudo, without a prompt.
why="$(secure_path "$dest_dir")" || die "$why; refusing to install a module that sudo would load as root"
# OpenPAM tries "<module>.2" before "<module>", so a stray file there would be
# loaded instead of this one.
[[ ! -e "$dest.2" && ! -L "$dest.2" ]] || die "$dest.2 exists and would be loaded instead of $dest; remove it first"

echo "2/4 staging the module, the probe and the new sudo_local as root (sudo)"
new="$(mktemp)"
stage=""
cleanup() {
    rm -f "$new"
    if [[ -n "$stage" ]]; then /usr/bin/sudo /bin/rm -rf "$stage"; fi
}
trap cleanup EXIT
stage="$(make_stage "$probe")"
stage_file "$root/build/$module" "$stage/$module"
# This module's line takes the place of the active pam_tid.so line, with the
# same control flag and options; that line stays, commented out behind a
# marker, for uninstall. See "Rewriting sudo_local" in scripts/lib.sh.
if ! { [[ -f "$sudo_local" ]] && cat "$sudo_local"; true; } | rewrite_for_install "$dest" > "$new"; then
    die "nothing changed"
fi
stage_file "$new" "$stage/sudo_local"
# From here on only the root-owned copies are used: they are what was shown,
# what libpam checks and what gets installed.

echo "3/4 review"
echo "    module: $dest, sha256 $(shasum -a 256 "$stage/$module" | cut -c1-16)"
echo "    $sudo_local:"
diff -u "$([[ -f "$sudo_local" ]] && echo "$sudo_local" || echo /dev/null)" "$stage/sudo_local" | sed 's/^/        /' || true
confirm "Install the module and write this sudo_local?" || die "cancelled; nothing changed"

echo "4/4 installing: check the new sudo_local, install the module, write sudo_local, check again (sudo)"
run_as_root root_install "$stage" "$dest" "$sudo_local" || die "nothing installed (see above)"

if [[ -e "$legacy_dest" ]]; then
    # Not deleted here: its directory may be user-writable, and a root rm in a
    # directory the user controls can be pointed at another file.
    echo
    echo "An older copy at $legacy_dest is no longer used. Check it is not"
    echo "referenced anywhere else, then remove it: sudo rm $legacy_dest"
fi

echo
echo "Installed. Active sudo_local lines:"
grep -v '^[[:space:]]*#' "$sudo_local" | sed 's/^/    /'
echo "Test in a new terminal: sudo -k; sudo /usr/bin/true"
