#!/bin/bash
# Installs pam_tid_context.so and switches /etc/pam.d/sudo_local to it.
#
# A PAM module that fails to load makes sudo refuse every login ("unable to
# initialize PAM"), whatever its control flag. So each step is gated on libpam
# accepting the result, and a rejected sudo_local is rolled back immediately.
# Keep a root shell open while running this anyway (see README, Recovery).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$root/scripts/lib.sh"
probe="$root/build/probe_load"

die() { echo "install: $*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "macOS only"
[[ -f "$root/build/$module" && -x "$probe" ]] || die "run 'just build' first"

echo "1/4 checking the built module loads in libpam"
"$probe" "$root/build/$module" || die "built module rejected by libpam; nothing changed"

echo "2/4 installing $dest (sudo)"
# Anyone who can write to a directory above the module can swap it for their
# own and get root from the next sudo, without a prompt.
why="$(secure_path "$dest_dir")" || die "$why; refusing to install a module that sudo would load as root"
# OpenPAM tries "<module>.2" before "<module>", so a stray file there would be
# loaded instead of this one.
[[ ! -e "$dest.2" && ! -L "$dest.2" ]] || die "$dest.2 exists and would be loaded instead of $dest; remove it first"
sudo install -d -o root -g wheel -m 755 "$dest_dir"
sudo install -o root -g wheel -m 444 "$root/build/$module" "$dest"
why="$(secure_path "$dest")" || die "$why; sudo_local not changed"
"$probe" "$dest" || die "installed module rejected by libpam; sudo_local not changed"

echo "3/4 writing $sudo_local"
backup=""
if [[ -f "$sudo_local" ]]; then
    backup="$sudo_local.bak-$(date +%Y%m%d-%H%M%S)"
    sudo cp -p "$sudo_local" "$backup"
    echo "    backup: $backup"
fi
new="$(mktemp)"
trap 'rm -f "$new"' EXIT
# Comment out active pam_tid.so / pam_tid_* lines, put ours where the first one
# was (keeps it after pam_reattach if present), append if there was none.
# Existing lines for this module (also at its old path) are dropped so
# re-running is idempotent.
{ [[ -f "$sudo_local" ]] && cat "$sudo_local"; true; } | awk -v dest="$dest" -v legacy="$legacy_dest" '
    BEGIN { ours = "auth       sufficient     " dest }
    /^[[:space:]]*#/ { print; next }
    $1 == "auth" && ($3 == dest || $3 == legacy) { next }
    $1 == "auth" && ($3 ~ /(^|\/)pam_tid(_[a-z]+)?\.so(\.2)?$/) {
        print "#" $0
        if (!done) { print ours; done = 1 }
        next
    }
    { print }
    END { if (!done) print ours }
' > "$new"
sudo install -o root -g wheel -m 444 "$new" "$sudo_local"

echo "4/4 checking the new $sudo_local loads in libpam"
if ! "$probe" "$sudo_local"; then
    if [[ -n "$backup" ]]; then
        sudo cp -p "$backup" "$sudo_local"
        die "new sudo_local rejected; restored $backup"
    fi
    sudo rm -f "$sudo_local"
    die "new sudo_local rejected; removed it (there was none before)"
fi

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
