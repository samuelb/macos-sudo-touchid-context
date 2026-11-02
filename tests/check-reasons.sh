#!/bin/bash
# Asserts the dialog reason for the argv/parent shapes sudo sees in practice.
# Needs build/reason_test (`just build`). No Touch ID prompt, no root.
set -euo pipefail

bin="$(cd "$(dirname "$0")/.." && pwd)/build/reason_test"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

expect() {  # expect <label> <substring> <actual>
    if [[ "$3" == *"$2"* ]]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s\n     want substring: %s\n     got:            %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

expect_not() {  # expect_not <label> <substring> <actual>
    if [[ "$3" != *"$2"* ]]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s\n     must not contain: %s\n     got:              %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

what() {  # the reason without the requester, for the command parser cases
    local out
    out="$("$bin" "$@")"
    printf '%s' "${out%% — requested by:*}"
}

fits() {  # fits <label> <actual>: at most 160 characters, the most the dialog is known to show
    local LC_ALL=en_US.UTF-8
    if (( ${#2} <= 160 )); then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s\n     %d characters: %s\n' "$1" "${#2}" "$2"
        fail=1
    fi
}

# brew's SystemCommand shape: /usr/bin/sudo [-A] -E -- <cmd>, parent is a script file.
printf '#!/bin/bash\n"%s" -E -- /usr/sbin/installer -pkg /opt/homebrew/Caskroom/zoom/6.4.0/zoom.pkg -target /\n' "$bin" > "$tmp/fake-brew"
chmod +x "$tmp/fake-brew"
out="$("$tmp/fake-brew" upgrade --cask zoom)"
expect "command after --"            "run: /usr/sbin/installer -pkg /opt/homebrew/Caskroom/zoom/6.4.0/zoom.pkg -target /" "$out"
expect "script parent named by file" "requested by: bash fake-brew upgrade --cask zoom" "$out"

# Interpreter parent (brew runs as `ruby -W1 --disable=gems,rubyopt …/brew.rb upgrade`):
# the script, not the interpreter, names the requester. perl ships with macOS.
# shellcheck disable=SC2016  # $ENV is Perl, not shell
printf 'system($ENV{BIN}, "-E", "--", "/usr/bin/true");\n' > "$tmp/brew.pl"
out="$(BIN="$bin" /usr/bin/perl -W -X "$tmp/brew.pl" upgrade --cask zoom)"
expect "interpreter and its flags dropped" "requested by: brew.pl upgrade --cask zoom" "$out"

# Leading options without --, including one that takes a value.
out="$("$bin" -u root -H /usr/bin/id -un)"
expect "options skipped, -u value skipped" "run: /usr/bin/id -un" "$out"

# sudo -s runs $SHELL, which the caller chooses, so the dialog names it.
out="$(SHELL=/bin/zsh "$bin" -s)"
expect "sudo -s names the shell" "run: /bin/zsh —" "$out"
out="$(SHELL=/tmp/evil "$bin" -s /usr/bin/id)"
expect "sudo -s <cmd> shows the shell and sudo's -c string" "run: /tmp/evil -c '\\/usr\\/bin\\/id' —" "$out"

# Inline shells are skipped and listed as "via"; `; :` stops bash exec'ing its last command.
out="$(/bin/bash -c '"$0" -- /usr/bin/true; :' "$bin")"
expect "inline shell listed as via" "(via bash -c)" "$out"
out="$(/bin/sh -c '/bin/bash -c '"'"'"$0" -- /usr/bin/true; :'"'"' "$0"; :' "$bin")"
expect "nested inline shells, outermost first" "(via sh -c → bash -c)" "$out"

# --- sudo's own parsing (parse_args.c): what the dialog names is what sudo runs.
me="$(id -un)"
# A "--" after the command belongs to the command; it does not start another one.
expect "-- inside the command is an argument" "run: /bin/sh -c 'echo hi' -- /usr/bin/true" "$(what /bin/sh -c 'echo hi' -- /usr/bin/true)"
expect "rm -rf -- dir"                        "run: /bin/rm -rf -- /tmp/x"                "$(what /bin/rm -rf -- /tmp/x)"
# Option values are not the command.
out="$(what --prompt 'Homebrew cask update' /usr/bin/id)"
expect     "--prompt value skipped"            "run: /usr/bin/id" "$out"
expect_not "--prompt text not shown"           "Homebrew" "$out"
expect "--user value"                          "run as postgres: /usr/bin/id" "$(what --user postgres /usr/bin/id)"
expect "--user=value"                          "run as postgres: /usr/bin/id" "$(what --user=postgres /usr/bin/id)"
expect "abbreviated long option"               "run as postgres: /usr/bin/id" "$(what --us postgres /usr/bin/id)"
expect "grouped short flags"                   "run as postgres: /usr/bin/id" "$(what -Eu postgres /usr/bin/id)"
expect "attached short value"                  "run as postgres: /usr/bin/id" "$(what -upostgres /usr/bin/id)"
expect "-g alone runs as the caller"           "run as $me with group staff: /usr/bin/id" "$(what -g staff /usr/bin/id)"
expect "-u root is not mentioned"              "run: /usr/bin/id" "$(what -u root /usr/bin/id)"
# VAR=value words reach the command and bypass sudo's environment filter.
expect "VAR=value shown"                       "run: BASH_ENV=/tmp/x.sh /bin/bash s.sh" "$(what -E BASH_ENV=/tmp/x.sh -- /bin/bash s.sh)"
expect "--preserve-env=list shown"             "run: BASH_ENV=/tmp/x.sh /bin/bash s.sh" "$(BASH_ENV=/tmp/x.sh what --preserve-env=BASH_ENV /bin/bash s.sh)"
expect "USER=<someone else> shown"             "run: USER=root /usr/bin/id" "$(what USER=root /usr/bin/id)"
# Homebrew's real argv (system_command.rb, sudo_prefix).
expect "Homebrew's own-name variables hidden"  "run: /usr/sbin/installer -pkg x.pkg -target /" \
    "$(what -u root -E LOGNAME="$me" USER="$me" USERNAME="$me" -- /usr/sbin/installer -pkg x.pkg -target /)"
# A command found through PATH is shown as the file sudo will run.
mkdir -p "$tmp/evil" && printf '#!/bin/sh\n' > "$tmp/evil/id" && chmod +x "$tmp/evil/id"
expect "PATH lookup"                           "run: /usr/bin/id -un" "$(PATH=/usr/bin:/bin what id -un)"
expect "PATH lookup names the caller's copy"   "run: $tmp/evil/id -un" "$(PATH="$tmp/evil:/usr/bin" what id -un)"
expect "a word after -- is never a variable"   "UNVERIFIED command (FOO=1 is not in PATH), called as: reason_test -- FOO=1 /usr/bin/id" "$(what -- FOO=1 /usr/bin/id)"
expect "-- as an option value still counts"    "UNVERIFIED command (FOO=1 is not in PATH)" "$(what -u -- FOO=1 /usr/bin/id)"
# Other modes.
expect "-e"                                    "edit: /etc/hosts" "$(what -e /etc/hosts)"
expect "-e relative file"                      "edit: /private/etc/hosts" "$(cd /etc && what -e hosts)"
expect "invoked as sudoedit"                   "edit: /etc/hosts" "$( (exec -a sudoedit "$bin" /etc/hosts) )"
expect "-i names the login shell"              "run as nobody (login shell): /usr/bin/false" "$(what -u nobody -i)"
expect "-l"                                    "list your sudo rights" "$(what -l)"
expect "-l <cmd>"                              "check whether you may run: /usr/bin/id" "$(what -l /usr/bin/id)"
expect "-v"                                    "refresh your cached sudo credentials" "$(what -v)"
expect "-k <cmd>"                              "run: /usr/bin/id" "$(what -k /usr/bin/id)"
# Anything it cannot be sure about makes the dialog a warning: the reason, then how
# sudo was called (argv[0] shortened to its last component), then the requester.
expect "ambiguous abbreviation"                "UNVERIFIED command (unknown or ambiguous option --pre), called as: reason_test --pre /usr/bin/id" "$(what --pre /usr/bin/id)"
expect "unknown option"                        "UNVERIFIED command (unknown option -X)" "$(what -X /bin/ls)"
expect "-R chroot"                             "UNVERIFIED command (-D/-R change where the command runs), called as: reason_test -R /tmp /bin/sh" "$(what -R /tmp /bin/sh)"
expect "-D chdir"                              "UNVERIFIED command (-D/-R" "$(what -D /tmp /bin/ls)"
expect "-h"                                    "UNVERIFIED command (-h/--host)" "$(what -h)"
expect "no command"                            "UNVERIFIED command (sudo without a command)" "$(what -n)"
expect "relative PATH entry"                   "UNVERIFIED command (relative PATH entry bin), called as: reason_test id" "$(PATH="bin:/usr/bin" what id)"
expect "only in the current directory"         "UNVERIFIED command (nosuchcmd could only come from . in PATH)" "$(PATH=".:/nonexistent" what nosuchcmd)"
# An empty argv[0] would shift KERN_PROCARGS2's argv by one: "", /tmp/evil, /usr/bin/true
# would read as "/usr/bin/true <first environment variable>".
expect "empty argv[0]"                         "UNVERIFIED command (sudo's argv[0] is empty), called as: '' /tmp/evil /usr/bin/true" \
    "$(/usr/bin/perl -e 'exec {$ARGV[0]} "", "/tmp/evil", "/usr/bin/true"' "$bin")"
# Caller-chosen text in the reason is escaped like the command.
out="$(PATH=$'a\nrequested by: softwareupdate:/usr/bin' what id)"
expect     "reason quotes caller text"          "UNVERIFIED command (relative PATH entry \$'a\\nrequested by'), called as: reason_test id" "$out"
expect_not "reason has no raw newline"          $'\n' "$out"

# --- Display: every argument reads back as itself.
# A newline cannot draw a fake line, and the em dash of " — requested by:" cannot be typed.
out="$(what -- /bin/echo $'x\nrequested by: softwareupdate')"
expect "newline escaped"                 "run: /bin/echo \$'x\\nrequested by: softwareupdate'" "$out"
expect_not "no raw newline"              $'\n' "$out"
expect "em dash escaped"                 "\$'x \\u2014 requested by: Software Update'" "$(what -- /bin/echo 'x — requested by: Software Update')"
expect "bidi override escaped"           "\$'/tmp/\\u202Etxt.sh'" "$(what -- /bin/echo $'/tmp/‮txt.sh')"
expect "look-alike letter escaped"       "run: \$'/usr/bin/\\u0456d'" "$(what /usr/bin/$'і'd)"
expect "argument boundaries visible"     "run: /bin/sh -c 'a; b'" "$(what /bin/sh -c 'a; b')"
expect "argument boundaries visible (2)" "run: /bin/sh -c 'a;' b" "$(what /bin/sh -c 'a;' b)"
expect "quote and empty word"            "run: /bin/echo 'it'\\''s' ''" "$(what /bin/echo "it's" '')"
expect "backslash inside an escape"      "run: /bin/echo \$'a\\\\b\\n'" "$(what /bin/echo $'a\\b\n')"
expect "arguments that are not UTF-8"    "UNVERIFIED command (arguments not readable or not UTF-8), called as: sudo /bin/echo \$'\\xFF'" \
    "$(/usr/bin/perl -e 'exec {$ARGV[0]} "sudo", "/bin/echo", "\xff"' "$bin")"

# The command of a normal dialog is never cut: one that does not fit makes the
# dialog a warning, which says so before the cut call.
long="$(printf 'x%.0s' {1..300})"
out="$("$bin" -- /bin/echo "$long")"
expect "long command: warning"           "UNVERIFIED command (too long to show in full: 315 characters), called as: reason_test -- /bin/echo xxx" "$out"
expect "long command: call cut"          "x… — requested by: " "$out"
fits   "long command: warning fits" "$out"
pad="$(printf ' %.0s' {1..200})"
expect "padding cannot push the end out" "UNVERIFIED command (too long to show in full" "$(what /bin/sh -c "$pad; evil")"
out="$(PATH="$long:/usr/bin" "$bin" "$long")"
fits   "long reason and call: warning fits" "$out"
expect "long reason cut"                 "UNVERIFIED command (relative PATH entry xxxxxxxxxxxxxxxxxxx…), called as: reason_test xxx" "$out"
# The requester is context the caller chooses anyway; it is cut, the command is not.
printf '#!/bin/bash\n"%s" -- /usr/bin/true\n' "$bin" > "$tmp/long-parent"
chmod +x "$tmp/long-parent"
out="$("$tmp/long-parent" "$long")"
expect "long requester cut"              "…" "$out"
expect "command intact"                  "run: /usr/bin/true — requested by: bash long-parent" "$out"

exit "$fail"
