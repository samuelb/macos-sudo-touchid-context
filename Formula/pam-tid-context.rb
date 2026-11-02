# Homebrew formula. This repository doubles as its tap:
#
#   brew tap laurigates/sudo-touchid-context https://github.com/laurigates/macos-sudo-touchid-context
#   brew trust --formula laurigates/sudo-touchid-context/pam-tid-context
#   brew install --HEAD laurigates/sudo-touchid-context/pam-tid-context
#
# The formula only builds the module and installs the pam-tid-context command.
# It does not touch sudo: Homebrew runs as the user, and sudo must never load a
# module from Homebrew's user-owned folders. `pam-tid-context install` copies it
# to the root-owned /usr/local/pam_tid_context and switches sudo_local to it.
class PamTidContext < Formula
  desc "Touch ID for sudo with a dialog that names the command and who asked"
  homepage "https://github.com/laurigates/macos-sudo-touchid-context"
  license "MIT"
  # Only HEAD until the first release tag; then add url and sha256 here.
  head "https://github.com/laurigates/macos-sudo-touchid-context.git", branch: "main"

  depends_on "just" => :build
  depends_on macos: :sonoma

  def install
    system "just", "build"
    system "scripts/package.sh", libexec
    bin.write_exec_script libexec/"scripts/pam-tid-context"
  end

  def caveats
    <<~EOS
      Homebrew does not change sudo. To switch sudo to this module, open a
      root shell in another window first (sudo -s), keep it open until you
      have tested sudo, and run:
        pam-tid-context install
      It copies the module to /usr/local/pam_tid_context, which only root can
      change, and sudo loads it from there, never from Homebrew's folders.

      After an upgrade, sudo keeps using the copy installed before:
      `pam-tid-context status` shows whether it matches, and
      `pam-tid-context install` updates it.

      Run `pam-tid-context uninstall` before `brew uninstall pam-tid-context`.
    EOS
  end

  test do
    # libpam loads the module, as sudo does.
    system libexec/"build/probe_load", libexec/"build/pam_tid_context.so"
    assert_match "usage: pam-tid-context", shell_output("#{bin}/pam-tid-context help")
  end
end
