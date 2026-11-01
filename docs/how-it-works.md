# How it works

Findings behind this module, with the evidence for each. Source citations are to
Apple's published code: [`apple-oss-distributions/pam_modules`][pam_modules] at tag
`pam_modules-217.100.6` and [`apple-oss-distributions/OpenPAM`][openpam] at tag
`OpenPAM-35` (the latest tags when this was written, October 2026). Observations
are from macOS 26.6.2 (25G83) on Apple silicon. That the shipped binaries match
those tags is an assumption; the probe results below are consistent with it.

[pam_modules]: https://github.com/apple-oss-distributions/pam_modules/tree/pam_modules-217.100.6
[openpam]: https://github.com/apple-oss-distributions/OpenPAM/tree/OpenPAM-35

## Why Apple's dialog cannot show the command

`modules/pam_tid/pam_tid.c` in `pam_modules`:

- It reads only the PAM user (`pam_get_user`). Its own `argc`/`argv` are the
  option words from the `pam.d` line, and it ignores them. Nothing about sudo's
  command reaches it.
- It checks Touch ID is usable with `LAEvaluatePolicy` and `kLAOptionNotInteractive`
  (no UI), passing the user's uid in `kLAOptionUserId` (lines 110–148).
- The dialog itself comes from `AuthorizationCopyRights` on the right
  `com.apple.security.sudo`, called with `kAuthorizationEmptyEnvironment`
  (lines 150–161). The environment is where a caller would put custom prompt
  text. The dialog is built from the calling process name (`sudo`) and the
  right's definition, which on a stock system has no `default-prompt`
  (`security authorizationdb read com.apple.security.sudo`). On macOS 26.6 it
  reads "sudo is trying to execute a command as administrator."
- The right's rule is `entitled` and `authenticate-session-owner` (`k-of-n` 2, so
  both must pass). A process without sudo's entitlement is refused without UI.
  Loading `pam_tid.so.2` into the test harness (copied as `sudo`) showed no
  dialog, and authd logged `Failed to authorize right 'com.apple.security.sudo'
  by client '…/sudo'`. That is why `just screenshot stock` needs real
  `/usr/bin/sudo` with `pam_tid.so` active.
- In `sudo -A` (askpass) mode it returns `PAM_AUTHINFO_UNAVAIL` without UI
  (lines 102–108), so sudo falls through to the password via the askpass helper.

So no argument, environment variable or `-p` prompt that a caller such as
Homebrew gives sudo can change the dialog. Changing it needs a different module.

## How this module gets the command into the dialog

`LAContext -evaluatePolicy:localizedReason:reply:` is the public LocalAuthentication
API; the dialog renders as "<process> is trying to <localizedReason>". A PAM
module runs inside the sudo process, so it can read:

- **sudo's own argv and environment** via `sysctl(KERN_PROCARGS2)` on
  `getpid()`. See [Reading sudo's arguments](#reading-sudos-arguments) for how
  they are turned into what the dialog says.
- **the requester** by walking parent pids (`KERN_PROC_PID` → `e_ppid`). Inline
  shell wrappers (`sh`/`bash`/`zsh … -c`) are skipped and listed as "via"; a
  shell running a script file is kept, because the file name identifies it. For
  an interpreter (`ruby`, `python`, `perl`, `node`, …) the interpreter and its
  flags are dropped so the script names the requester.
- Absolute paths in the requester are shortened to their last component. The
  command keeps full paths, since those are what is being authorized.
- Every argument is written so that it reads back as exactly one argument with
  exactly its characters, in bash/zsh quoting:
  - Only printable ASCII is shown as it is. Anything else is escaped inside
    `$'…'`: newlines and other control characters, bidi overrides such as
    U+202E, zero-width and format characters, look-alike letters (Cyrillic
    `і` in `/usr/bin/іd`). So an argument cannot draw a fake "requested by:"
    line, reorder what is shown, or pass for another path.
  - A word with a space or shell punctuation, or an empty word, is
    single-quoted, so `sh -c 'a; b'` and `sh -c 'a;' b` look different.
- The reason is capped at 160 characters; the dialog wraps long text at `/` and
  showed a ~150-character reason in full. The command is never shortened,
  because a cut hides exactly the part that matters (`sh -c "<200 spaces>;
  evil"`). When it does not fit, the module steps aside and sudo asks for the
  password. Only the requester is cut, with "…".

### Reading sudo's arguments

The dialog has to name what sudo will actually do, so the module parses sudo's
argv the way sudo does. The rules are mirrored from `parse_args()` in sudo
1.9.17p2 as Apple ships it ([`apple-oss-distributions/sudo`][sudo] tag
`sudo-114.100.11`, `sudo/src/parse_args.c`):

- Options end at the first word that is not one (`getopt_long` with `+`). A
  `--` ends them only while they are still being read; a `--` among the
  command's arguments (`sudo rm -rf -- dir`) belongs to the command.
- Long options take `--opt=value` or `--opt value`, and may be abbreviated to
  any unique prefix (`--us root`), as macOS `getopt_long` allows. Short flags
  can be grouped and values attached (`-Eu root`, `-uroot`).
- `VAR=value` words may appear between options. They reach the command and,
  with macOS's default `%admin ALL = (ALL) ALL` rule (which implies `SETENV`),
  bypass sudo's environment filter, so the dialog shows them.
  `--preserve-env=A,B` passes those variables from the caller's environment and
  is shown the same way. `LOGNAME`, `USER` and `USERNAME` set to the caller's own
  name (Homebrew passes all three) are left out.
- A command without a `/` is looked up in the caller's `PATH` like sudoers'
  `find_path()`, and the dialog shows the file found (`sudo ls` reads
  "run: /bin/ls"). If sudoers sets `secure_path` (macOS does not), sudo searches
  that instead, so the path shown can differ; both lists then come from places
  the caller cannot choose.
- The rest of the dialog depends on the mode:
  - `-u`/`-g` add "as postgres" or "with group staff".
  - `sudo -s` shows the shell from `$SHELL`, which the caller chooses, and the
    `-c` string sudo builds from the command.
  - `sudo -i` shows the target user's login shell.
  - `-e`/`sudoedit` show "edit:" and the absolute file paths.
  - `-l` and `-v` say what they do.

Whatever the module cannot be sure about makes it return `PAM_AUTHINFO_UNAVAIL`,
so sudo asks for the password instead. That includes:

- unknown or ambiguous options;
- `-D`/`-R`, which change where the command runs;
- `-h`;
- a command found only through `.` or a relative `PATH` entry;
- arguments that are not UTF-8;
- an empty `argv[0]`. `KERN_PROCARGS2` cannot tell it apart from the padding in
  front of it, so every argument would shift by one, and the module checks
  sudo's in-memory `argv[0]` for it.
- a command too long to show in full (the 160-character cap above).

[sudo]: https://github.com/apple-oss-distributions/sudo/tree/sudo-114.100.11

Third-party modules that use the same API exist (for example
[`biscuitehh/pam-watchid`](https://github.com/biscuitehh/pam-watchid)); they pass a
fixed `reason=` option from the `pam.d` line.

## Touch ID inside sudo: evaluate as the invoking user

sudo is setuid root, so a module calling `LAContext` runs with euid 0, and
`coreauthd` evaluates the policy **for root**. The first in-sudo run failed
without a dialog; the unified log showed why:

```
coreauthd … ContextProxy[…] created for Context[…] uid:0
coreauthd … evaluatePolicy … returned Error Domain=com.apple.LocalAuthentication
  Code=-7 "No identities are enrolled."
```

The same code had worked from a test program running as the user. Apple's
`pam_tid` avoids this with the private `kLAOptionUserId`. This module uses public
API only: it calls `seteuid(getuid())` for the duration of the evaluation and
restores the saved euid afterwards (a setuid process may switch between its real
and saved ids). If restoring fails it calls `abort()` rather than continue in
sudo with the wrong euid.

Before prompting it requires that the PAM user, the real uid (who ran sudo) and
the console user (`SCDynamicStoreCopyConsoleUser`) are the same account, because
`LAContext` authenticates whoever is at the console, not the PAM user. Without
that check another account running sudo in your GUI session could be approved
with your fingerprint.

## A module that fails to load locks sudo

In OpenPAM, a module that cannot be loaded makes the whole service fail to
configure. The control flag (`sufficient`, `optional`) is never consulted, and
lines already loaded do not help.

From `openpam/lib/` at `OpenPAM-35`:

1. `openpam_configure.c:216–219`: each module is loaded while its line is
   parsed. On `NULL` the parser jumps to `fail` and returns `-1`.
2. `openpam_configure.c:181–184`: an `include` (sudo includes `sudo_local`)
   passes a `-1` from the included file up.
3. `openpam_configure.c:376–397`: `openpam_configure` clears every loaded chain
   and returns `PAM_SYSTEM_ERR`.
4. `pam_start.c:73–85`: `pam_start` fails. Its fallback to a hard-coded stock
   Apple chain applies only to processes flagged `CS_INSTALLER`, not to sudo.

A missing policy **file** is different: `openpam_read_chain_from_path` treats
`ENOENT` as an empty file (`openpam_configure.c:267–271`), so a missing
`sudo_local` is harmless.

Observed with `tests/probe_load.c` against the system libpam (return value =
module lines loaded, `-1` = rejected):

```
control: stock pam_tid.so          -> 1
missing, sufficient                -> -1
missing, optional                  -> -1
stock line, then missing optional  -> -1
```

sudo reports any load failure as `sudo: unable to initialize PAM: No such file or
directory`. Reports of it, first-hand:
[pam-watchid#26](https://github.com/biscuitehh/pam-watchid/issues/26) (comment of
2023-12-11: "Adding this plugin and enabling it in sudo_local breaks sudo
completely"). Others describe the same message for a wrong architecture where the
file existed, so the text does not identify the cause.

Ways to hit it: the module file is deleted while the line remains (uninstall in
the wrong order), a wrong path, a module built for the other architecture (this
project builds universal arm64 + x86_64), or a relative path. A path without a
leading `/` is looked up under OpenPAM's module directory
(`openpam_dynamic.c:210–248`), not the working directory.

## Where the module is installed

sudo loads every module named in `sudo_local` as root, during `pam_start`,
before anyone authenticates. Apple's OpenPAM does not check who owns a module or
the directories above it (`openpam_dynamic.c` only `dlopen`s the path; the
`openpam_check_path_owner_perms` check of newer OpenPAM releases is not called).
So anyone who can replace the file, or rename any directory above it, gets root
from the next `sudo`, with no prompt. Making the file itself root-owned and 0444
does not help when its parent can be renamed: renaming a directory only needs
write access to the directory above it.

Earlier versions installed to `/usr/local/lib/pam`. On many Macs
`/usr/local/lib` is owned by the user (Homebrew's Intel layout, or an installer
that created it), which made the module replaceable by any process running as
that user. The module now goes to `/usr/local/pam_tid_context`, directly under
`/usr/local`, which macOS creates as `root:wheel 0755`, and `install.sh` refuses
to install unless every existing component of that path:

- is not a symlink,
- is owned by root,
- is not writable by group or others,
- has no ACL entry that allows anything (ACLs can grant write access that the
  mode bits do not show).

It also refuses when `pam_tid_context.so.2` exists next to the module, because
OpenPAM tries `<name>.2` before `<name>` (`openpam_dynamic.c`). `just status`
repeats the check for the installed copy. The rule is OpenSSH's `StrictModes`.

Apple's `pam_tid.so` lives in `/usr/lib/pam`, which System Integrity
Protection covers; a third-party module cannot get that protection, only the
ownership rule above. A `pam_reattach.so` under Homebrew's user-owned
`/opt/homebrew/lib/pam` has the exposure this section describes.

## Rewriting sudo_local

The rewrite changes only which module does Touch ID, not what the policy means
(`rewrite_for_install` and `rewrite_for_uninstall` in `scripts/lib.sh`):

- **Control flag, options and position are kept.** Earlier versions replaced
  any Touch ID line with `auth sufficient <module>`. A policy that requires
  Touch ID and then the password (`auth required pam_tid.so` before the
  password module) became one where Touch ID alone skips the password. Now the
  flag and options are copied from the line being replaced.
- **Uninstall restores exactly what install replaced.** The replaced line is
  kept as `#pam_tid_context-disabled: <line>`, verbatim. When there was no
  Touch ID line, `#pam_tid_context-added` marks the line as new. Earlier
  versions re-enabled the first `#auth sufficient pam_tid.so` on uninstall.
  That could be Apple's template line, turning on Touch ID for someone who
  never had it, and indented, absolute-path or non-`sufficient` lines were
  never restored.
- **Re-installing edits the line in place.** Earlier versions dropped it and
  appended a new one at the end, after any later line (a `pam_deny`, for
  example).
- **Unclear configurations are refused:** more than one active Touch ID line,
  or another `pam_tid_*` module.

A file written by an install from before the markers has neither marker. For
it, uninstall re-enables a commented `pam_tid.so` line directly above this
module's line, as before. It warns that the line may be Apple's template
rather than a line install commented out.

## Installing as root

`install.sh` and `uninstall.sh` prepare everything as the user, then copy it
into a root-owned staging directory under `/private/tmp`, show it, and run the
privileged part as one root process (`run_as_root` in `scripts/lib.sh`):

- **What is checked is what gets installed.** Earlier versions checked the
  module in the user-owned `build/` and wrote the new `sudo_local` to a
  user-owned `mktemp` file, and only later copied both with `sudo`. Code running
  as the user could swap either in between, for example for a `sudo_local` with
  `auth sufficient pam_permit.so`. The staged copies are `root:wheel 0444` in a
  root-owned directory: the user can read them (for the diff) but not change,
  rename or replace them.
- **The rollback does not need sudo.** Earlier versions wrote `sudo_local`,
  checked it, and restored the backup with a fresh `sudo cp`. If libpam rejected
  the new file, that `sudo` failed too ("unable to initialize PAM"), so the
  rollback could not run in exactly the case it was written for. Now the new
  `sudo_local` is checked before it is written, with its module line pointed at
  the staged copy of the module. Then the write, the check in place and the
  restore all happen in the same root process. When updating, the module it
  replaces is kept and put back as well.
- **Fixed tool paths.** The root process calls `/usr/bin/install`, `/bin/cp`,
  `/bin/rm` and the staged probe by absolute path. `sudo` keeps the caller's
  `PATH`, so a plain `install` could be the caller's own program.

The probe runs as root inside that process, from its staged copy. It is built
from this repository like the module, which runs as root inside sudo anyway.

`tests/check-install.sh` runs the same transaction code on temporary files with
a stand-in probe, including each rollback path.

## Unsigned modules do load in sudo

`openpam_dynamic.c:70–124` (`openpam_dlopen`): if `dlopen` of a readable module
fails and the process enforces library validation, OpenPAM clears it with
`csops(CS_OPS_CLEAR_LV)` and retries. For that call to succeed the process needs
an entitlement; Apple DTS stated that sudo has it
([developer forums thread 729622](https://developer.apple.com/forums/thread/729622),
May 2023: sudo "opts out of library validation" to load PAM modules). Reading
sudo's entitlements needs root (`/usr/bin/sudo` is mode 4511), so this project did
not check them directly.

Observed: the ad-hoc-signed module built by `clang` loads in `/usr/bin/sudo` on
macOS 26.6.2. A second report on the same version:
[Homebrew discussion #6597](https://github.com/orgs/Homebrew/discussions/6597)
(2026-08-27: a self-built module "works well (at least on Tahoe 26.6.2)" in sudo).
The same discussion shows `sshd-session` rejecting third-party modules on macOS
26, so the result is specific to sudo.

## Fallback behaviour

| Situation | Module returns | sudo then |
|---|---|---|
| Touch ID approved | `PAM_SUCCESS` | runs the command |
| Cancel / "Use Password" | `PAM_AUTH_ERR` | terminal password prompt (no second dialog, because `pam_tid.so` is commented out) |
| `sudo -A` | `PAM_AUTHINFO_UNAVAIL` | askpass helper |
| No GUI session (SSH) | `PAM_AUTHINFO_UNAVAIL` | terminal password prompt |
| Other account / no enrolled finger | `PAM_AUTHINFO_UNAVAIL` | terminal password prompt |
| Arguments the module cannot read with certainty (see [Reading sudo's arguments](#reading-sudos-arguments)) | `PAM_AUTHINFO_UNAVAIL` | terminal password prompt |

Keeping Apple's `pam_tid.so` active *after* this module would show a second
Touch ID dialog whenever the first is cancelled, which is why install comments
it out rather than stacking.

## Homebrew specifics

Homebrew calls `/usr/bin/sudo` by absolute path
(`Library/Homebrew/system_command.rb`, `sudo_prefix`), so a shell alias or
wrapper never sees it. Before its first sudo call in a run it executes
`sudo --reset-timestamp` (`Library/Homebrew/utils/sudo.sh`), discarding cached
credentials, so each run that needs root prompts again. Typical triggers are
cask `.pkg` installers (`cask/pkg.rb`), uninstall scripts and launchctl steps,
and removing root-owned files under `/Applications`. Homebrew adds `-A` when
`SUDO_ASKPASS` is set, which skips Touch ID entirely.

Its Ruby process appears as
`…/portable-ruby/current/bin/ruby -W1 --disable=gems,rubyopt …/brew.rb <args>`,
which the requester walk shows as `brew.rb <args>`.

## Testing

| Tool | Proves | Needs |
|---|---|---|
| `tests/check-reasons.sh` (via `build/reason_test`) | command parsing and requester formatting for real argv/parent shapes | nothing |
| `tests/probe_load.c` | the system libpam accepts a module or a whole policy file — the check sudo's `pam_start` performs | nothing |
| `tests/harness.c` (`just try-dialog`) | a real Touch ID dialog with the reason, outside sudo | Touch ID |
| `just try-sudo` | the installed module inside setuid sudo, including the euid switch | install |

`probe_load` calls `openpam_read_chain_from_filehandle`, an OpenPAM-internal
function the system libpam exports. It is not public API and could disappear; the
probe checks the symbol and runs a control (`pam_tid.so` must load) first, and
exits 2 rather than reporting a result if either fails. An earlier version passed
the wrong style constant (`pam_conf_style` is 0 in the enum, `pam_d_style` 1);
every line was skipped and the control returned 0, which is how the control
caught it.

## Debugging notes

- **Unified log:** the module logs under subsystem `pam_tid_context`
  (`just logs`). In zsh, `log` is a shell builtin, so `log show …` never reaches
  macOS's tool and prints nothing useful; call `/usr/bin/log`.
- `/usr/bin/log show` has rendered the module's messages as `<compose failure
  [UUID]>`: the event is recorded but the format string is not resolved. The
  LocalAuthentication and `coreauthd` lines around it are readable and were enough
  to diagnose the uid problem.
- Useful predicate while testing:
  `process == "sudo" OR process == "coreauthd" OR subsystem == "com.apple.LocalAuthentication"`.
