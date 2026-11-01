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
expect() {  # expect <label> <substring> <actual>
    if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "want substring: $2 | got: $3"; fi
}
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

# --- commit_install / commit_uninstall: the root transaction, run here as the
# user on temporary files. The probe is a stand-in that records what it was
# asked about and rejects any file whose path matches $REJECT, or that
# contains BROKEN.
me="$(id -un):$(id -gn)"
expect_eq() {  # expect_eq <label> <want> <got>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "want: $2 | got: $3"; fi
}
new_case() {  # new_case <name>: fresh root, stage and sudo_local under $tmp/<name>
    c="$tmp/$1"
    stage="$c/stage" dest="$c/root/pam_tid_context/pam_tid_context.so" policy="$c/pam.d/sudo_local"
    mkdir -p "$stage" "$c/pam.d"
    cat > "$stage/probe_load" <<'PROBE'
#!/bin/bash
echo "$1" >> "${0%/*}/probe.log"
# shellcheck disable=SC2254  # $REJECT is a glob on purpose
case "$1" in $REJECT) exit 1 ;; esac
if grep -q BROKEN "$1" 2>/dev/null; then exit 1; fi
exit 0
PROBE
    chmod +x "$stage/probe_load"
    echo "new module" > "$stage/pam_tid_context.so"
    printf 'auth       sufficient     pam_tid.so\n' > "$policy"
    printf '#auth       sufficient     pam_tid.so\nauth       sufficient     %s\n' "$dest" > "$stage/sudo_local"
    export REJECT="/nonexistent"
}
run_install()   { commit_install   "$stage" "$dest" "$policy" "$me" >/dev/null 2>"$c/err"; }
run_uninstall() { commit_uninstall "$stage" "$dest" "$policy" "$me" "${1:-yes}" >/dev/null 2>"$c/err"; }

new_case install-ok
if run_install; then ok "install succeeds"; else bad "install succeeds" "$(cat "$c/err")"; fi
expect_eq "module installed"              "new module" "$(cat "$dest")"
expect_eq "module read-only"              "444" "$(stat -f %Lp "$dest")"
expect_eq "sudo_local is the staged one"  "$(cat "$stage/sudo_local")" "$(cat "$policy")"
expect_eq "backup of the old sudo_local"  "auth       sufficient     pam_tid.so" "$(cat "$policy".bak-*)"
expect_eq "candidate checked with the staged module before writing" \
    "$stage/pam_tid_context.so" "$(awk '$1 == "auth" && $3 ~ /context/ { print $3 }' "$stage/sudo_local.check")"
expect_eq "probe order: candidate, module, sudo_local in place" \
    "$stage/sudo_local.check $dest $policy" "$(tr '\n' ' ' < "$stage/probe.log" | sed 's/ $//')"

new_case candidate-rejected
echo BROKEN >> "$stage/sudo_local"
if run_install; then bad "rejected candidate stops the install" "it succeeded"; else ok "rejected candidate stops the install"; fi
expect_eq "nothing installed"             "absent" "$([[ -e "$dest" ]] && echo present || echo absent)"
expect_eq "sudo_local untouched"          "auth       sufficient     pam_tid.so" "$(cat "$policy")"

new_case module-rejected
mkdir -p "${dest%/*}" && echo "old module" > "$dest" && chmod 444 "$dest"
REJECT="$dest"
if run_install; then bad "rejected module stops the install" "it succeeded"; else ok "rejected module stops the install"; fi
expect_eq "previous module put back"      "old module" "$(cat "$dest")"
expect_eq "sudo_local untouched"          "auth       sufficient     pam_tid.so" "$(cat "$policy")"

new_case policy-rejected-in-place
mkdir -p "${dest%/*}" && echo "old module" > "$dest" && chmod 444 "$dest"
chmod 644 "$policy"
REJECT="$policy"
if run_install; then bad "sudo_local rejected in place is rolled back" "it succeeded"; else ok "sudo_local rejected in place is rolled back"; fi
expect_eq "old sudo_local restored without a new sudo" "auth       sufficient     pam_tid.so" "$(cat "$policy")"
expect_eq "its mode restored too"         "644" "$(stat -f %Lp "$policy")"
expect_eq "previous module put back"      "old module" "$(cat "$dest")"

new_case policy-rejected-no-previous
rm -f "$policy"
REJECT="$policy"
if run_install; then bad "rejected new sudo_local removed" "it succeeded"; else ok "rejected new sudo_local removed"; fi
expect_eq "no sudo_local, as before"      "absent" "$([[ -e "$policy" ]] && echo present || echo absent)"
expect_eq "no module, as before"          "absent" "$([[ -e "$dest" ]] && echo present || echo absent)"

new_case uninstall-ok
run_install
printf 'auth       sufficient     pam_tid.so\n' > "$stage/sudo_local"
if run_uninstall; then ok "uninstall succeeds"; else bad "uninstall succeeds" "$(cat "$c/err")"; fi
expect_eq "sudo_local without the module" "auth       sufficient     pam_tid.so" "$(cat "$policy")"
expect_eq "module removed"                "absent" "$([[ -e "$dest" ]] && echo present || echo absent)"
expect_eq "its directory removed"         "absent" "$([[ -e "${dest%/*}" ]] && echo present || echo absent)"

new_case uninstall-rejected-in-place
run_install
installed="$(cat "$policy")"
printf 'auth       sufficient     pam_tid.so\n' > "$stage/sudo_local"
REJECT="$policy"
if run_uninstall; then bad "rejected rewrite is rolled back" "it succeeded"; else ok "rejected rewrite is rolled back"; fi
expect_eq "sudo_local restored"           "$installed" "$(cat "$policy")"
expect_eq "module left in place"          "new module" "$(cat "$dest")"

new_case uninstall-still-referenced
run_install
rm -f "$stage/sudo_local"
if run_uninstall; then bad "module still named: not removed" "it succeeded"; else ok "module still named: not removed"; fi
expect_eq "module left in place"          "new module" "$(cat "$dest")"

new_case uninstall-unsafe-dir
run_install
printf 'auth       sufficient     pam_tid.so\n' > "$stage/sudo_local"
if run_uninstall no; then ok "unsafe directory: sudo_local still restored"; else bad "unsafe directory: sudo_local still restored" "$(cat "$c/err")"; fi
expect_eq "module not deleted"            "new module" "$(cat "$dest")"

# The script run_as_root gives to `sudo /bin/bash -c`, run here without sudo. In a
# user-owned directory it must refuse before writing anything.
new_case root-script
for fn in root_install root_uninstall; do
    if /bin/bash -n -c "$(root_script "$fn")"; then ok "$fn script parses"; else bad "$fn script parses" "bash -n failed"; fi
done
if /bin/bash -c "$(root_script root_install)" root_install "$stage" "$dest" "$policy" 2>"$c/err"; then
    bad "root_install refuses a user-owned directory" "it succeeded"
else
    expect "root_install refuses a user-owned directory" "refusing to install" "$(cat "$c/err")"
fi
expect_eq "nothing written"               "auth       sufficient     pam_tid.so" "$(cat "$policy")"

exit "$fail"
