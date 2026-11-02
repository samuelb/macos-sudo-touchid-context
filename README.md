# macos-sudo-touchid-context

A Touch ID PAM module for macOS `sudo` whose dialog says what is being authorized
and which process asked.

Apple's `pam_tid.so` shows the same dialog for every request: "sudo is trying to
execute a command as administrator." When a background job (a `brew upgrade`
installing a cask `.pkg`, a launchd script) triggers it, the dialog gives no way
to tell what you are approving.

<table>
  <tr>
    <th>Apple's <code>pam_tid.so</code></th>
    <th>This module</th>
  </tr>
  <tr>
    <td valign="top"><img src="docs/images/dialog-stock.png" width="320"
         alt="Touch ID dialog titled sudo: 'sudo is trying to execute a command as administrator. Touch ID or enter your password to allow this.' with Use Password and Cancel buttons"></td>
    <td valign="top"><img src="docs/images/dialog.png" width="320"
         alt="Touch ID dialog titled sudo: 'sudo is trying to run: /usr/sbin/installer -pkg /opt/homebrew/Caskroom/zoom/6.4.0/zoomusInstallerFull.pkg -target / — requested by: brew.rb upgrade --cask zoom. Touch ID or enter your password to allow this.' with Use Password and Cancel buttons"></td>
  </tr>
</table>

Both are captured with `just screenshot`. Apple's dialog comes from real
`/usr/bin/sudo` (it reads the same for every command). This module's runs through
the test harness with the argv and parent process brew gives sudo.

Inline shell wrappers are skipped when naming the requester, so a job started via
`zsh -c '…'` shows as `claude (via zsh -c)` rather than the shell's command line.

When the module cannot tell for sure what sudo will run, the dialog says so
first: "run an UNVERIFIED command (<reason>), called as: <sudo's arguments>"
([details](docs/how-it-works.md#reading-sudos-arguments)).

## Status

Working on macOS 26.6 (Apple silicon) for sudo: Touch ID approval, and cancel
falling back to the terminal password prompt, are tested. The screenshot uses
brew's process shape; a live cask upgrade has not been observed yet
([#1](https://github.com/laurigates/macos-sudo-touchid-context/issues/1)). Small and young; read
[`docs/how-it-works.md`](docs/how-it-works.md) before installing.

## Requirements

- macOS 14 or later (`/etc/pam.d/sudo_local` exists from macOS 14)
- Xcode Command Line Tools (`clang`), [`just`](https://github.com/casey/just)
- A Mac with Touch ID and at least one enrolled finger

## Install

> **Keep a root shell open in another window (`sudo -s`) until you have tested
> the result.** If `sudo_local` names a module that cannot be loaded, macOS
> refuses every sudo login, whatever the control flag says
> ([details](docs/how-it-works.md#a-module-that-fails-to-load-locks-sudo)).

```
just test        # builds, checks reason formatting, checks libpam accepts the module
just try-dialog  # optional: a real Touch ID dialog from the module, outside sudo
just install     # installs to /usr/local/pam_tid_context, rewrites /etc/pam.d/sudo_local
just try-sudo    # in a new terminal: sudo -k; sudo /usr/bin/id -un
```

`just install`:

1. Asks libpam whether the built module loads. Checks that every directory
   above `/usr/local/pam_tid_context` is root-owned and writable only by root,
   and refuses to install otherwise: sudo loads the module as root before anyone
   authenticates, so a user who can replace it gets root without a prompt
   ([details](docs/how-it-works.md#where-the-module-is-installed)).
2. Copies the module, the libpam probe and the new `sudo_local` into a
   root-owned staging directory. In the new `sudo_local`, this module's line
   takes the place of the active `pam_tid.so` line, with the same control flag
   and options (so it stays after `pam_reattach.so`, and `required` stays
   `required`). The old line stays, commented out behind a
   `#pam_tid_context-disabled:` marker. With no Touch ID line, this module's
   line goes after Apple's commented template line, behind a
   `#pam_tid_context-added` marker. More than one active Touch ID line, or
   another `pam_tid_*` module, is refused. Re-running updates the line in
   place ([details](docs/how-it-works.md#rewriting-sudo_local)). From here on
   only these copies are used, so nothing running as you can swap a file
   between the check and the install
   ([details](docs/how-it-works.md#installing-as-root)).
3. Shows the module's hash and a diff of `sudo_local`, and asks before changing
   anything.
4. In a single root process, with one `sudo`:
   - asks libpam whether the new `sudo_local` loads;
   - installs `/usr/local/pam_tid_context/pam_tid_context.so` (root:wheel,
     0444) and checks it;
   - backs up `sudo_local` to `sudo_local.bak-<timestamp>` and writes the new
     one;
   - checks it again in place, and restores the backup and the previous module
     if libpam rejects it.

The libpam check is `tests/probe_load.c`, which calls the policy parser sudo
itself uses. See [Testing](docs/how-it-works.md#testing).

## Options

Options go after the module path on its line in `/etc/pam.d/sudo_local`:

```
auth       sufficient     /usr/local/pam_tid_context/pam_tid_context.so timeout=30
```

| Option | Does |
|---|---|
| `timeout=<seconds>` | How long the dialog waits for an answer before sudo asks for the password: 5 to 600, default 60. Other values are ignored and logged |

Re-running `just install` keeps them.

## Recovery

If sudo prints `sudo: unable to initialize PAM: No such file or directory`, the
module could not be loaded. The message reads the same whatever the actual cause:
a missing file, wrong architecture, or wrong path. From the root shell:

```
cp -p /etc/pam.d/sudo_local.bak-<timestamp> /etc/pam.d/sudo_local
```

Without a root shell, `osascript -e 'do shell script "cp -p /etc/pam.d/sudo_local.bak-<timestamp> /etc/pam.d/sudo_local" with administrator privileges'`
authenticates through the macOS admin dialog rather than sudo's PAM stack.

## Uninstall

```
just uninstall
```

Removes this module's line from `sudo_local` and restores exactly the line
install replaced (nothing, if it replaced nothing), shows the diff and asks, then, in one root process, checks
the result with libpam before and after writing it, and only then deletes the
module file. Deleting the file first would lock sudo.

## Other recipes

| Recipe | Does |
|---|---|
| `just status` | Active `sudo_local` lines; installed vs built module hash; whether only root can replace the installed module |
| `just screenshot [stock]` | Regenerates `docs/images/dialog.png`, or `dialog-stock.png` with `stock` (needs `pam_tid.so` as the active `sudo_local` line). Shows a dialog; wait for the capture message before touching |
| `just logs [minutes]` | The module's unified-log lines (uses `/usr/bin/log`; in zsh, `log` is a builtin) |
| `just lint` | shellcheck the scripts |

## How it works

[`docs/how-it-works.md`](docs/how-it-works.md) covers why Apple's dialog cannot
show the command, how this module gets it, the uid detail that makes Touch ID
work inside sudo, the OpenPAM load-failure behaviour, and the evidence for each.

## License

MIT
