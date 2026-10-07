# Template for the cask in a homebrew-tap repository (Casks/upthere.rb).
cask "upthere" do
  version "0.1.0"
  sha256 :no_check # replace with the DMG's sha256 for each release

  url "https://github.com/Mateu6/upthere/releases/download/v#{version}/Upthere-v#{version}.dmg"
  name "Upthere"
  desc "Now Playing and Claude Code activity in the MacBook notch"
  homepage "https://github.com/Mateu6/upthere"

  depends_on macos: ">= :tahoe"

  app "Upthere.app"

  zap trash: [
    "~/Library/Application Support/upthere",
    "~/Library/Preferences/dev.upthere.app.plist",
  ]
end
