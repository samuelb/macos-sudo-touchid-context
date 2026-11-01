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
expect "sudo -s <cmd> shows the shell and sudo's -c string" 'run: /tmp/evil -c \/usr\/bin\/id —' "$out"

# Inline shells are skipped and listed as "via"; `; :` stops bash exec'ing its last command.
out="$(/bin/bash -c '"$0" -- /usr/bin/true; :' "$bin")"
expect "inline shell listed as via" "(via bash -c)" "$out"
out="$(/bin/sh -c '/bin/bash -c '"'"'"$0" -- /usr/bin/true; :'"'"' "$0"; :' "$bin")"
expect "nested inline shells, outermost first" "(via sh -c → bash -c)" "$out"

# --- sudo's own parsing (parse_args.c): what the dialog names is what sudo runs.
me="$(id -un)"
# A "--" after the command belongs to the command; it does not start another one.
expect "-- inside the command is an argument" "run: /bin/sh -c echo hi -- /usr/bin/true" "$(what /bin/sh -c 'echo hi' -- /usr/bin/true)"
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
expect "a word after -- is never a variable"   "fallback: FOO=1 is not in PATH" "$(what -- FOO=1 /usr/bin/id)"
expect "-- as an option value still counts"    "fallback: FOO=1 is not in PATH" "$(what -u -- FOO=1 /usr/bin/id)"
# Other modes.
expect "-e"                                    "edit: /etc/hosts" "$(what -e /etc/hosts)"
expect "-e relative file"                      "edit: /private/etc/hosts" "$(cd /etc && what -e hosts)"
expect "invoked as sudoedit"                   "edit: /etc/hosts" "$( (exec -a sudoedit "$bin" /etc/hosts) )"
expect "-i names the login shell"              "run as nobody (login shell): /usr/bin/false" "$(what -u nobody -i)"
expect "-l"                                    "list your sudo rights" "$(what -l)"
expect "-l <cmd>"                              "check whether you may run: /usr/bin/id" "$(what -l /usr/bin/id)"
expect "-v"                                    "refresh your cached sudo credentials" "$(what -v)"
expect "-k <cmd>"                              "run: /usr/bin/id" "$(what -k /usr/bin/id)"
# Anything it cannot be sure about leaves sudo to ask for the password.
expect "ambiguous abbreviation"                "fallback: unknown or ambiguous option --pre" "$(what --pre /usr/bin/id)"
expect "unknown option"                        "fallback: unknown option -X" "$(what -X /bin/ls)"
expect "-R chroot"                             "fallback: -D/-R" "$(what -R /tmp /bin/sh)"
expect "-D chdir"                              "fallback: -D/-R" "$(what -D /tmp /bin/ls)"
expect "-h"                                    "fallback: -h/--host" "$(what -h)"
expect "no command"                            "fallback: sudo without a command" "$(what -n)"
expect "relative PATH entry"                   "fallback: PATH has a relative entry" "$(PATH="bin:/usr/bin" what id)"
expect "only in the current directory"         "fallback: nosuchcmd is not in PATH outside" "$(PATH=".:/nonexistent" what nosuchcmd)"
# An empty argv[0] would shift KERN_PROCARGS2's argv by one: "", /tmp/evil, /usr/bin/true
# would read as "/usr/bin/true <first environment variable>".
expect "empty argv[0]"                         "fallback: sudo's argv[0] is empty" \
    "$(/usr/bin/perl -e 'exec {$ARGV[0]} "", "/tmp/evil", "/usr/bin/true"' "$bin")"

# Long commands are truncated with an ellipsis.
long="$(printf 'x%.0s' {1..300})"
out="$("$bin" -- /bin/echo "$long")"
expect "long command truncated" "…" "$out"

exit "$fail"
