#!/bin/bash
# Asserts how the module reads its options from its sudo_local line.
# Needs build/option_test (`just build`).
set -euo pipefail

bin="$(cd "$(dirname "$0")/.." && pwd)/build/option_test"
fail=0

expect() {  # expect <label> <timeout> <options…>
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

expect "no options: 60 seconds"           60
expect "timeout=30"                       30  timeout=30
expect "lowest allowed"                   5   timeout=5
expect "highest allowed"                  600 timeout=600
# Out of range or not a whole number of seconds: ignored, so the default stays.
expect "too short"                        60  timeout=4
expect "too long"                         60  timeout=601
expect "zero"                             60  timeout=0
expect "negative"                         60  timeout=-30
expect "not a number"                     60  timeout=abc
expect "unit after the number"            60  timeout=30s
expect "empty"                            60  timeout=
expect "overflows a long"                 60  timeout=99999999999999999999
expect "other options ignored"            30  no_warn timeout=30 debug
expect "an invalid value keeps the last"  30  timeout=30 timeout=abc
expect "the last valid value wins"        45  timeout=30 timeout=45

exit "$fail"
