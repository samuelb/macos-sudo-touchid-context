#!/bin/bash
# Checks scripts/package.sh and the pam-tid-context command in the layout the
# Homebrew formula installs, in a temporary directory. Needs build/ (`just
# build`). Nothing here needs root: install and uninstall get stdin from
# /dev/null, so they stop at their terminal check, before any sudo.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n     %s\n' "$1" "$2"; fail=1; }
expect() {  # expect <label> <exit code> <substring> <command…>; stdin is /dev/null
    local label=$1 want_rc=$2 want=$3 out rc=0
    shift 3
    out="$("$@" </dev/null 2>&1)" || rc=$?
    if [[ "$rc" != "$want_rc" ]]; then
        bad "$label" "want exit $want_rc, got $rc: $out"
    elif [[ "$out" != *"$want"* ]]; then
        bad "$label" "want substring: $want | got: $out"
    else
        ok "$label"
    fi
}

# A space in the path catches quoting mistakes.
pkg="$tmp/lib exec"
"$repo/scripts/package.sh" "$pkg"

# --- the layout
for f in scripts/pam-tid-context scripts/install.sh scripts/uninstall.sh scripts/status.sh \
         build/pam_tid_context.so build/probe_load; do
    if [[ -x "$pkg/$f" ]]; then ok "packaged: $f"; else bad "packaged: $f" "missing or not executable"; fi
done
if [[ -f "$pkg/scripts/lib.sh" && ! -x "$pkg/scripts/lib.sh" ]]; then ok "packaged: scripts/lib.sh (sourced, not run)"
else bad "packaged: scripts/lib.sh" "missing, or executable"; fi
if cmp -s "$repo/build/pam_tid_context.so" "$pkg/build/pam_tid_context.so"; then ok "packaged module is the built one"
else bad "packaged module is the built one" "differs from build/pam_tid_context.so"; fi

mkdir -p "$tmp/checkout/scripts"
cp "$repo/scripts/package.sh" "$tmp/checkout/scripts/"
expect "package refuses an unbuilt checkout" 1 "run 'just build' first" "$tmp/checkout/scripts/package.sh" "$tmp/out"

# --- the command
cmd="$pkg/scripts/pam-tid-context"
expect "help"                       0 "usage: pam-tid-context <command>" "$cmd" help
expect "no command: usage"          2 "usage: pam-tid-context"           "$cmd"
expect "unknown command: usage"     2 "usage: pam-tid-context"           "$cmd" upgrade
expect "extra argument: usage"      2 "usage: pam-tid-context"           "$cmd" install now

built="$(shasum -a 256 "$repo/build/pam_tid_context.so" | cut -c1-16)"
expect "status reads the packaged module" 0 "built:     $built" "$cmd" status

# Homebrew's bin/pam-tid-context is a script that execs the packaged command
# (write_exec_script), reached through a symlink in the prefix's bin.
mkdir -p "$tmp/cellar/bin" "$tmp/prefix/bin"
printf '#!/bin/bash\nexec "%s" "$@"\n' "$cmd" > "$tmp/cellar/bin/pam-tid-context"
chmod +x "$tmp/cellar/bin/pam-tid-context"
ln -s "$tmp/cellar/bin/pam-tid-context" "$tmp/prefix/bin/pam-tid-context"
expect "status through Homebrew's bin link" 0 "built:     $built" "$tmp/prefix/bin/pam-tid-context" status

# Reaching the terminal check means the script found lib.sh, the module and the
# probe in the package.
expect "install finds its files"    1 "install: run it from a terminal"   "$cmd" install
expect "uninstall finds its files"  1 "uninstall: run it from a terminal" "$cmd" uninstall

exit "$fail"
