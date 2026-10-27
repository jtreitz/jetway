class Jetway < Formula
  desc "Menu bar client for the Lufthansa GlobalProtect VPN (Prisma Access)"
  homepage "https://github.com/jtreitz/jetway"
  url "https://github.com/jtreitz/jetway/archive/refs/tags/v0.1.7.tar.gz"
  sha256 "1992884e20e2e182f27da990de8bafd8b2362f1c3e3dc17d774bc87a53a876e4"
  head "https://github.com/jtreitz/jetway.git", branch: "main"

  depends_on "openconnect"
  depends_on macos: :ventura

  def install
    # SwiftPM keeps caches under $HOME; keep them inside the sandboxed build directory.
    ENV["HOME"] = (buildpath/"home").to_s
    (buildpath/"home").mkpath
    system "scripts/build.sh"
    prefix.install "build/Jetway.app"
    libexec.install "bin/jetway"
    (bin/"jetway").write_env_script libexec/"jetway", JETWAY_APP_SRC: opt_prefix/"Jetway.app"
  end

  def caveats
    <<~EOS
      Jetway was built on this Mac. Put it into /Applications and start it with:
        jetway install
      Run the same after `brew upgrade jetway`.
    EOS
  end

  test do
    assert_predicate prefix/"Jetway.app/Contents/MacOS/Jetway", :executable?
  end
end
