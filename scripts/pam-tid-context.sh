#!/bin/bash
# The pam-tid-context command of a packaged install, such as the Homebrew
# formula. scripts/package.sh lays the package out like a checkout (scripts/
# next to a built build/) and installs this file as scripts/pam-tid-context, so
# each command runs the same script as its just recipe.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
usage: pam-tid-context <command>

  install    copy the module to /usr/local/pam_tid_context and switch
             /etc/pam.d/sudo_local to it; keep a root shell open (sudo -s)
             until you have tested it. Run it again after an upgrade.
  uninstall  switch sudo_local back to Apple's pam_tid.so, then remove the
             module. Run it before uninstalling the package.
  status     show the active sudo_local lines, and whether the installed
             module matches this package's
EOF
}

if [[ $# -ne 1 ]]; then usage >&2; exit 2; fi
case "$1" in
    install) exec "$here/install.sh" ;;
    uninstall) exec "$here/uninstall.sh" ;;
    status) exec "$here/status.sh" ;;
    help | -h | --help) usage ;;
    *) usage >&2; exit 2 ;;
esac
