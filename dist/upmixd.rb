# Homebrew formula for upmixd. Lives in the mzelem/homebrew-tap repository as
# Formula/upmixd.rb; this copy is the source of truth, synced at release time.
# URL and sha256 are stamped by the release process.
class Upmixd < Formula
  desc "Stereo-to-5.1 upmix daemon with live EQ and menu-bar panel"
  homepage "https://github.com/mzelem/upmixd"
  url "https://github.com/mzelem/upmixd/archive/refs/tags/v__VERSION__.tar.gz"
  sha256 "__SHA256__"
  license "MIT"

  depends_on :macos
  depends_on xcode: ["15.0", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/upmixd"
    libexec.install ".build/release/upmix-panel"
    libexec.install "dist/UpmixPanel-Info.plist"
    libexec.install "dist/com.utw.upmix-panel.plist"
    bin.install "dist/upmixd-panel"
  end

  service do
    run [opt_bin/"upmixd", "--set-default"]
    keep_alive true
    process_type :interactive
    log_path var/"log/upmixd.log"
    error_log_path var/"log/upmixd.log"
  end

  def caveats
    <<~EOS
      upmixd captures system audio through the BlackHole virtual driver:
        brew install --cask blackhole-2ch
      then restart coreaudiod (sudo killall coreaudiod) or reboot once.

      Start the daemon (also starts at login):
        brew services start upmixd

      Optional menu-bar panel with EQ sliders:
        upmixd-panel install

      All settings live in ~/.config/upmixd.conf, reloaded the instant
      you save.

      Previously installed from source with `make install`? Run
      `make uninstall` first — otherwise two daemons will fight over the
      audio device. After `brew upgrade`, rerun `upmixd-panel install`
      to refresh the panel app copy.
    EOS
  end

  test do
    output = shell_output("#{bin}/upmixd --bogus 2>&1", 64)
    assert_match "usage", output
  end
end
