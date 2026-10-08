# Mirror of Casks/upthere.rb in github.com/Mateu6/homebrew-tap, which the
# release workflow bumps (version + sha256) on every tag.
cask "upthere" do
  version "0.4.2"
  sha256 "2958974353ed94b464bb9bc13fead10f970a7dffe718b8de7abe07536ad0420e"

  url "https://github.com/Mateu6/upthere/releases/download/v#{version}/Upthere-#{version}.dmg"
  name "Upthere"
  desc "Now Playing and Claude Code activity beside the MacBook notch"
  homepage "https://github.com/Mateu6/upthere"

  livecheck do
    url "https://github.com/Mateu6/upthere/releases/latest/download/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :tahoe

  app "Upthere.app"

  uninstall quit: "dev.upthere.app"

  zap trash: [
    "~/Library/Application Support/upthere",
    "~/Library/Caches/dev.upthere.app",
    "~/Library/HTTPStorages/dev.upthere.app",
    "~/Library/Preferences/dev.upthere.app.plist",
  ]

  caveats <<~EOS
    Upthere isn't notarized yet. If macOS blocks the first launch, open
    System Settings > Privacy & Security and click "Open Anyway", or run:
      xattr -dr com.apple.quarantine "#{appdir}/Upthere.app"
  EOS
end
