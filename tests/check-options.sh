#!/bin/bash
# Asserts how the module reads its options from its sudo_local line.
# Needs build/option_test (`just build`).
set -euo pipefail

bin="$(cd "$(dirname "$0")/.." && pwd)/build/option_test"
fail=0

expect() {  # expect <label> <settings> <options…>
    local label=$1 want=$2 got
    shift 2
    got="$("$bin" "$@")"
    if [[ "$got" == "$want" ]]; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$label" "$want" "$got"
        fail=1
    fi
}

d="timeout=60"
expect "no options: the defaults"         "$d"
expect "timeout=30"                       "timeout=30"  timeout=30
expect "lowest allowed"                   "timeout=5"   timeout=5
expect "highest allowed"                  "timeout=600" timeout=600
# Out of range or not a whole number of seconds: ignored, so the default stays.
expect "too short"                        "$d" timeout=4
expect "too long"                         "$d" timeout=601
expect "zero"                             "$d" timeout=0
expect "negative"                         "$d" timeout=-30
expect "not a number"                     "$d" timeout=abc
expect "unit after the number"            "$d" timeout=30s
expect "empty"                            "$d" timeout=
expect "overflows a long"                 "$d" timeout=99999999999999999999
expect "an invalid value keeps the last"  "timeout=30"  timeout=30 timeout=abc
expect "the last valid value wins"        "timeout=45"  timeout=30 timeout=45
# The dialog text is logged as private unless the audit flag is set.
expect "audit"                            "timeout=60 audit" audit
expect "audit is case-sensitive"          "$d" AUDIT
expect "audit takes no value"             "$d" audit=yes
expect "audit as a prefix ignored"        "$d" auditing
expect "both options"                     "timeout=30 audit" timeout=30 audit
expect "other options ignored"            "timeout=30 audit" no_warn timeout=30 debug audit

exit "$fail"
