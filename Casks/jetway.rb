# Homebrew cask for Jetway. Lives in the tap repo (homebrew-jetway/Casks/jetway.rb).
# Install:  brew tap lh-innovationhub/jetway && brew install --cask --no-quarantine jetway
cask "jetway" do
  version "0.1.0"
  sha256 "bcf827b6b4822a26545f2e2c8ea1fd6915afc8a6bc37ddf8469064434222fce5"

  url "https://github.com/lh-innovationhub/jetway/releases/download/v#{version}/Jetway-#{version}.zip"
  name "Jetway"
  desc "Menu bar client for GlobalProtect/Prisma Access VPN with Entra sign-in"
  homepage "https://github.com/lh-innovationhub/jetway"

  depends_on macos: ">= :ventura"
  depends_on formula: "openconnect"

  app "Jetway-#{version}/Jetway.app"

  uninstall quit: "dev.treitz.Jetway"

  zap trash: [
    "~/Library/Application Support/Jetway",
    "~/Library/Logs/Jetway",
    "~/Library/Preferences/dev.treitz.Jetway.plist",
  ]

  caveats <<~EOS
    Jetway is not notarized. Install with --no-quarantine, or after installing run:
      xattr -dr com.apple.quarantine /Applications/Jetway.app
    If you enable "Enable Root Privileges" in Jetway's settings, turn it off again before
    uninstalling so the sudoers rule is removed.
  EOS
end
