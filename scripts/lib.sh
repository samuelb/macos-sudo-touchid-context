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
