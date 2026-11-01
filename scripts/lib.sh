# Shared by install.sh, uninstall.sh, `just status` and tests/check-install.sh.
# Sourced, not run.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables are used by the scripts that source this

module=pam_tid_context.so

# sudo loads the module as root before anyone authenticates, so whoever can
# replace the file, or rename any directory above it, gets root without a
# prompt. Every directory on the path must therefore be root-owned and not
# writable by anyone else. /usr/local/lib does not qualify on many Macs (it is
# owned by the user when Homebrew or an installer created it), so the module
# gets its own directory directly under /usr/local, which macOS creates as
# root:wheel 0755.
dest_dir=/usr/local/pam_tid_context
dest="$dest_dir/$module"

# Where earlier versions installed the module. That directory sits inside the
# user-owned /usr/local/lib on many Macs.
legacy_dest=/usr/local/lib/pam/$module

sudo_local=/etc/pam.d/sudo_local

# path_component_ok <path>: one existing path component is a real directory or
# file (not a symlink), owned by root, not writable by group or others, and
# without an ACL entry that allows anything (an "allow" entry can grant write
# access that the mode bits do not show). Prints the reason when it is not.
path_component_ok() {
    local p=$1 owner mode
    if [[ -L "$p" ]]; then
        echo "$p is a symlink"
        return 1
    fi
    read -r owner mode < <(/usr/bin/stat -f '%u %Lp' "$p")
    if [[ "$owner" != 0 ]]; then
        echo "$p is owned by uid $owner, not root"
        return 1
    fi
    if (( (8#$mode & 8#022) != 0 )); then
        echo "$p is writable by group or others (mode $mode)"
        return 1
    fi
    if /bin/ls -lde "$p" | /usr/bin/grep -Eq '^ *[0-9]+: .* allow '; then
        echo "$p has an ACL entry that allows access"
        return 1
    fi
}

# secure_path <absolute path>: every existing component from / down to the path
# passes path_component_ok. Components that do not exist yet are fine: install
# creates them as root. Same rule as OpenSSH's StrictModes and OpenPAM's
# openpam_check_path_owner_perms (which Apple's OpenPAM does not call).
secure_path() {
    local target=$1 p="" rest
    if [[ "$target" != /* ]]; then
        echo "$target is not an absolute path"
        return 1
    fi
    path_component_ok / || return 1
    rest=${target#/}
    while [[ -n "$rest" ]]; do
        p="$p/${rest%%/*}"
        if [[ "$rest" == */* ]]; then rest=${rest#*/}; else rest=""; fi
        [[ -e "$p" || -L "$p" ]] || return 0
        path_component_ok "$p" || return 1
    done
}

# ---- Privileged steps
#
# install.sh and uninstall.sh prepare everything as the user, copy it into a
# root-owned staging directory, show it, and only then run root_install or
# root_uninstall below: one root bash process (run_as_root) using absolute tool
# paths. That way:
# - what libpam checks is what gets installed. The staged copies cannot be
#   changed by the user between the check and the copy, unlike build/ and a
#   user-owned mktemp file, which unprivileged code could swap (for example
#   for a sudo_local with "auth sufficient pam_permit.so") after they were
#   checked and before root copied them;
# - checking the new sudo_local, writing it, checking it in place, and the
#   rollback all happen in that one process. The rollback never needs a fresh
#   sudo, which a rejected sudo_local would already have broken;
# - the caller's PATH cannot substitute another install, cp or rm.
#
# Staging layout: <stage>/pam_tid_context.so (module), <stage>/probe_load (the
# libpam probe), <stage>/sudo_local (the new policy; for uninstall, present only
# when sudo_local changes).

# commit_install <stage> <dest> <sudo_local> <owner:group>
# <owner:group> is root:wheel; tests pass their own user to run the same code on
# temporary files.
commit_install() {
    local stage=$1 dest=$2 sudo_local=$3 owner=${4%:*} group=${4#*:}
    local module="$stage/${dest##*/}" probe="$stage/probe_load" previous="" backup=""

    # 1. The new sudo_local must load before anything is written. Its line for
    #    this module points at the staged copy, which is the file installed next.
    /usr/bin/awk -v d="$dest" -v s="$module" '!/^[[:space:]]*#/ && $3 == d { $3 = s } { print }' \
        "$stage/sudo_local" > "$stage/sudo_local.check"
    if ! "$probe" "$stage/sudo_local.check"; then
        echo "the new sudo_local is rejected by libpam; nothing changed" >&2
        return 1
    fi

    # 2. The module, keeping the copy it replaces for the rollback.
    /usr/bin/install -d -o "$owner" -g "$group" -m 755 "${dest%/*}"
    if [[ -f "$dest" ]]; then
        previous="$stage/previous.so"
        /bin/cp -p "$dest" "$previous"
    fi
    /usr/bin/install -o "$owner" -g "$group" -m 444 "$module" "$dest"
    if ! "$probe" "$dest"; then
        if [[ -n "$previous" ]]; then /usr/bin/install -o "$owner" -g "$group" -m 444 "$previous" "$dest"; else /bin/rm -f "$dest"; fi
        echo "the installed module is rejected by libpam; put the previous one back, sudo_local not changed" >&2
        return 1
    fi

    # 3. sudo_local, checked again in place and restored right here if rejected.
    if [[ -f "$sudo_local" ]]; then
        backup="$sudo_local.bak-$(/bin/date +%Y%m%d-%H%M%S)"
        /bin/cp -p "$sudo_local" "$backup"
        echo "    backup: $backup"
    fi
    /usr/bin/install -o "$owner" -g "$group" -m 444 "$stage/sudo_local" "$sudo_local"
    if ! "$probe" "$sudo_local"; then
        if [[ -n "$backup" ]]; then
            /usr/bin/install -o "$owner" -g "$group" -m "$(/usr/bin/stat -f %Lp "$backup")" "$backup" "$sudo_local"
        else
            /bin/rm -f "$sudo_local"
        fi
        if [[ -n "$previous" ]]; then /usr/bin/install -o "$owner" -g "$group" -m 444 "$previous" "$dest"; else /bin/rm -f "$dest"; fi
        echo "the new sudo_local is rejected by libpam in place; restored ${backup:-the previous state (no sudo_local)}" >&2
        return 1
    fi
}

# commit_uninstall <stage> <dest> <sudo_local> <owner:group> <remove the module: yes|no>
commit_uninstall() {
    local stage=$1 dest=$2 sudo_local=$3 owner=${4%:*} group=${4#*:} remove=$5
    local probe="$stage/probe_load" backup

    if [[ -f "$stage/sudo_local" ]]; then
        if ! "$probe" "$stage/sudo_local"; then
            echo "the rewritten sudo_local is rejected by libpam; nothing changed" >&2
            return 1
        fi
        backup="$sudo_local.bak-$(/bin/date +%Y%m%d-%H%M%S)"
        /bin/cp -p "$sudo_local" "$backup"
        echo "    backup: $backup"
        /usr/bin/install -o "$owner" -g "$group" -m 444 "$stage/sudo_local" "$sudo_local"
        if ! "$probe" "$sudo_local"; then
            /usr/bin/install -o "$owner" -g "$group" -m "$(/usr/bin/stat -f %Lp "$backup")" "$backup" "$sudo_local"
            echo "the rewritten sudo_local is rejected by libpam in place; restored $backup, module left in place" >&2
            return 1
        fi
    fi

    # The line goes first, the file second: deleting a module that sudo_local
    # still names locks sudo.
    if /usr/bin/grep -v '^[[:space:]]*#' "$sudo_local" 2>/dev/null | /usr/bin/grep -q 'pam_tid_context\.so'; then
        echo "sudo_local still references the module; not removing it" >&2
        return 1
    fi
    if [[ "$remove" == yes ]]; then
        /bin/rm -f "$dest"
        /bin/rmdir "${dest%/*}" 2>/dev/null || true
    fi
}

# Root side of install.sh: the path checks once more, as root and right before
# writing, then the commit.
root_install() {  # <stage> <dest> <sudo_local>
    local why
    if ! why="$(secure_path "${2%/*}")"; then
        echo "$why; refusing to install a module that sudo would load as root" >&2
        return 1
    fi
    if [[ -e "$2.2" || -L "$2.2" ]]; then
        echo "$2.2 exists and OpenPAM would load it instead of $2; remove it first" >&2
        return 1
    fi
    commit_install "$1" "$2" "$3" root:wheel
}

# Root side of uninstall.sh. The module file is deleted as root only from a
# directory only root can change.
root_uninstall() {  # <stage> <dest> <sudo_local>
    local why remove=yes
    if ! why="$(secure_path "${2%/*}")"; then
        echo "not removing $2 as root: $why; remove it by hand" >&2
        remove=no
    fi
    commit_uninstall "$1" "$2" "$3" root:wheel "$remove"
}

# root_script <root_install|root_uninstall>: the script run_as_root hands to
# bash, with exactly the functions above.
root_script() {
    printf 'set -euo pipefail\n%s\n%s "$@"\n' \
        "$(declare -f path_component_ok secure_path commit_install commit_uninstall root_install root_uninstall)" "$1"
}

# run_as_root <root_install|root_uninstall> <args…>: one root bash process, so the
# whole transaction needs a single sudo.
run_as_root() {
    local fn=$1
    shift
    /usr/bin/sudo /bin/bash -c "$(root_script "$fn")" "$fn" "$@"
}

# make_stage <probe>: a root-owned staging directory (0755, so its contents can
# be shown), with a root-owned copy of the probe. Prints its path.
make_stage() {
    local stage
    stage="$(/usr/bin/sudo /usr/bin/mktemp -d /private/tmp/pam_tid_context.XXXXXX)"
    /usr/bin/sudo /bin/chmod 755 "$stage"
    /usr/bin/sudo /usr/bin/install -o root -g wheel -m 555 "$1" "$stage/probe_load"
    echo "$stage"
}

# stage_file <file> <stage>/<name>: a root-owned, read-only copy.
stage_file() {
    /usr/bin/sudo /usr/bin/install -o root -g wheel -m 444 "$1" "$2"
}

# confirm <question>: asks on the terminal; anything but y/yes cancels.
confirm() {
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]]
}
