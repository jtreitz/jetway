class Jetway < Formula
  desc "Menu bar client for the Lufthansa GlobalProtect VPN (Prisma Access)"
  homepage "https://github.com/jtreitz/jetway"
  url "https://github.com/jtreitz/jetway/archive/refs/tags/v0.1.5.tar.gz"
  sha256 "3903e0126e9afb8fac3025b2e27443c57b9d4b5498d5e870972920631f16ad09"
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
