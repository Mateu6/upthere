# Mirror of Casks/upthere.rb in github.com/Mateu6/homebrew-tap, which the
# release workflow bumps (version + sha256) on every tag.
cask "upthere" do
  version "0.4.1"
  sha256 "2c2dd7c4b53ac9605230efec006025a9880e11ef5fba5486fbf1c60379ec25dd"

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
