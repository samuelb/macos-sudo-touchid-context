# macos-sudo-touchid-context task runner — `just` lists recipes

cflags := "-Wall -Werror -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=14.0"
frameworks := "-framework Foundation -framework LocalAuthentication -framework SystemConfiguration -framework Security -lpam"

# List available recipes
default:
    @just --list

# Build the module (universal arm64 + x86_64) and the test tools into build/
build:
    mkdir -p build
    clang {{cflags}} -bundle -o build/pam_tid_context.so src/pam_tid_context.m {{frameworks}}
    clang {{cflags}} -o build/reason_test tests/reason_test.m {{frameworks}}
    clang {{cflags}} -o build/option_test tests/option_test.m {{frameworks}}
    clang {{cflags}} -o build/module_test tests/module_test.m {{frameworks}}
    clang -Wall -Werror -o build/probe_load tests/probe_load.c -lpam
    clang -Wall -Werror -o build/harness tests/harness.c -lpam

# Non-interactive checks: reason formatting, module options and error handling, install helpers, packaging, libpam accepting the built module
test: build
    tests/check-reasons.sh
    tests/check-options.sh
    build/module_test
    tests/check-install.sh
    tests/check-package.sh
    build/probe_load build/pam_tid_context.so

# Show a real Touch ID dialog from the built module, outside sudo (no system changes)
try-dialog: build
    build/harness -E -- /usr/sbin/installer -pkg /opt/homebrew/Caskroom/example/1.0/example.pkg -target /

# Regenerate docs/images/dialog.png, or dialog-stock.png with `stock` (wait for the capture before touching)
screenshot mode="module": build
    swiftc -O -o build/windows scripts/windows.swift
    scripts/screenshot.sh {{mode}}

# Install the module and switch /etc/pam.d/sudo_local to it (keep a root shell open)
install: build
    scripts/install.sh

# Restore Apple's pam_tid.so in sudo_local, then remove the module
uninstall: build
    scripts/uninstall.sh

# Exercise the installed module through real sudo (forgets cached credentials first)
try-sudo:
    sudo -k
    sudo /usr/bin/id -un

# Show active sudo_local lines, whether the installed module matches the build, and whether only root can replace it
status:
    scripts/status.sh

# Recent log lines from the module (/usr/bin/log: in zsh, `log` is a builtin)
logs minutes="10":
    /usr/bin/log show --last {{minutes}}m --info --style compact --predicate 'subsystem == "pam_tid_context"'

# Lint shell scripts
lint:
    shellcheck -x tests/*.sh scripts/*.sh

# Remove build outputs
clean:
    rm -rf build
