require "./spec_helper"

ASSET = "zane-test-asset"

# Published CLI releases, served through Archive.download, and an installed
# `zane` for them to replace.
private class CliRegistry
  getter dir : Path
  getter downloads = {} of String => Bytes
  getter fetched = [] of String

  def initialize
    @dir = Path[Dir.tempdir] / "zane-self-#{Random::Secure.hex(8)}"
    Dir.mkdir_p(@dir / "bin")
  end

  def executable : Path
    @dir / "bin" / "zane"
  end

  def base(tag : String) : String
    "#{Zane::SelfUpdate::URL}/releases/download/#{tag}"
  end

  def publish(tag : String, binary : String = "new zane #{tag}", sums : String? = nil,
              latest : Bool = true, draft : Bool = false) : Nil
    @downloads["#{base(tag)}/#{ASSET}"] = binary.to_slice
    @downloads["#{base(tag)}/SHA256SUMS"] = (sums || "#{Zane::SHA256.hexdigest(binary)}  #{ASSET}\n").to_slice
    json = {"tag_name" => tag, "draft" => draft,
            "assets" => [{"name" => ASSET, "size" => binary.bytesize}, {"name" => "SHA256SUMS"}]}.to_json
    @downloads["#{Zane::SelfUpdate::API}/latest"] = json.to_slice if latest
    @downloads["#{Zane::SelfUpdate::API}/tags/#{tag}"] = json.to_slice
  end
end

private def with_cli_releases(current : String = "v0.1", &)
  registry = CliRegistry.new
  File.write(registry.executable, "old zane")
  download = Zane::Archive.download
  executable, installed, check = Zane::SelfUpdate.executable, Zane::SelfUpdate.current, Zane::SelfUpdate.check
  Zane::Archive.download = ->(url : String, path : Path) {
    registry.fetched << url
    File.write(path, registry.downloads[url]? || raise Zane::UserError.new("404 #{url}"))
    nil
  }
  Zane::SelfUpdate.executable = -> { registry.executable }
  Zane::SelfUpdate.current = current
  Zane::SelfUpdate.check = ->(binary : Path, tag : String) {
    raise Zane::UserError.new("does not run") unless File.read(binary) == "new zane #{tag}"
    nil
  }
  begin
    yield registry
  ensure
    Zane::Archive.download = download
    Zane::SelfUpdate.executable, Zane::SelfUpdate.current, Zane::SelfUpdate.check = executable, installed, check
    FileUtils.rm_rf(registry.dir)
  end
end

private def self_update(tag : String? = nil) : {Int32, String, String}
  output, error = IO::Memory.new, IO::Memory.new
  status = begin
    result = Zane::SelfUpdate.run(tag, asset: ASSET)
    Zane::Commands::SelfCommand.describe(result, output)
    0
  rescue e : Zane::UserError
    error.puts e.message
    1
  end
  {status, output.to_s, error.to_s}
end

# What the update directory holds besides the binary itself.
private def leftovers(registry : CliRegistry) : Array(String)
  Dir.children(registry.dir / "bin").reject("zane").sort
end

describe Zane::SelfUpdate do
  it "replaces the binary with the latest release, verified, and leaves nothing beside it" do
    with_cli_releases do |registry|
      registry.publish("v0.2")
      status, output, error = self_update
      {status, error}.should eq({0, ""})
      output.should eq "Updated zane v0.1 -> v0.2 at #{registry.executable}.\n"
      File.read(registry.executable).should eq "new zane v0.2"
      leftovers(registry).should be_empty
      {% unless flag?(:win32) %}
        File::Info.executable?(registry.executable).should be_true
      {% end %}
    end
  end

  it "installs the version named, older ones included" do
    with_cli_releases("v0.3") do |registry|
      registry.publish("v0.3")
      registry.publish("v0.2.1", latest: false)
      status, output, _ = self_update("v0.2.1")
      status.should eq 0
      output.should eq "Updated zane v0.3 -> v0.2.1 at #{registry.executable}.\n"
      File.read(registry.executable).should eq "new zane v0.2.1"
      registry.fetched.should contain "#{Zane::SelfUpdate::API}/tags/v0.2.1"
    end
  end

  it "changes nothing when this binary is already the release" do
    with_cli_releases("v0.2") do |registry|
      registry.publish("v0.2")
      status, output, _ = self_update
      status.should eq 0
      output.should eq "zane v0.2 is already installed at #{registry.executable}; nothing changed.\n"
      File.read(registry.executable).should eq "old zane"
      registry.fetched.should eq ["#{Zane::SelfUpdate::API}/latest"]
    end
  end

  it "counts a missing patch as 0, so v0.2.0 is already v0.2" do
    with_cli_releases("v0.2.0") do |registry|
      registry.publish("v0.2")
      status, output, _ = self_update
      status.should eq 0
      output.should contain "zane v0.2 is already installed"
      File.read(registry.executable).should eq "old zane"
    end
  end

  it "names the binary this host's releases publish" do
    workflow = File.read(Path[__DIR__].parent / ".github" / "workflows" / "release.yml")
    if asset = Zane::SelfUpdate.asset
      workflow.should contain " dist/#{asset}\n"
      workflow.should match(/sha256sum .*\b#{Regex.escape(asset)}\b/)
    end
  end

  it "knows the files Nix and Homebrew own" do
    Zane::SelfUpdate.package_manager("/nix/store/abc-zane-0.2/bin/zane").should eq "Nix"
    Zane::SelfUpdate.package_manager("/opt/homebrew/Cellar/zane/0.2/bin/zane").should eq "Homebrew"
    Zane::SelfUpdate.package_manager("/home/me/.local/bin/zane").should be_nil
  end

  it "does not move to an older latest release unless it is named" do
    with_cli_releases("v0.3") do |registry|
      registry.publish("v0.2")
      status, output, _ = self_update
      status.should eq 0
      output.should contain "newer than the latest release, v0.2; nothing changed"
      File.read(registry.executable).should eq "old zane"
    end
  end

  it "refuses a binary whose checksum does not match, and keeps the old one" do
    with_cli_releases do |registry|
      registry.publish("v0.2", sums: "#{"0" * 64}  #{ASSET}\n")
      status, _, error = self_update
      status.should eq 1
      error.should contain "checksum mismatch for zane v0.2; nothing was installed"
      File.read(registry.executable).should eq "old zane"
      leftovers(registry).should be_empty
    end
  end

  it "refuses checksums that do not name the binary exactly once" do
    with_cli_releases do |registry|
      registry.publish("v0.2", sums: "#{"0" * 64}  other\n")
      status, _, error = self_update
      status.should eq 1
      error.should contain "SHA256SUMS must contain exactly one valid checksum for #{ASSET}"
    end
  end

  it "refuses a binary that does not run, and keeps the old one" do
    with_cli_releases do |registry|
      registry.publish("v0.2", binary: "broken")
      status, _, error = self_update
      status.should eq 1
      error.should contain "does not run"
      File.read(registry.executable).should eq "old zane"
      leftovers(registry).should be_empty
    end
  end

  it "refuses an invalid version, a draft, and a release without this platform's binary" do
    with_cli_releases do |registry|
      self_update("latest")[2].should contain "`latest` is not a zane version"
      registry.publish("v0.2", draft: true)
      self_update[2].should contain "v0.2 is a draft zane release"
      json = {"tag_name" => "v0.4", "draft" => false, "assets" => [{"name" => "SHA256SUMS"}]}.to_json
      registry.downloads["#{Zane::SelfUpdate::API}/latest"] = json.to_slice
      self_update[2].should contain "zane v0.4 has no #{ASSET} and checksums"
      File.read(registry.executable).should eq "old zane"
    end
  end

  it "refuses to replace a development build" do
    with_cli_releases("v0.0-dev") do |registry|
      registry.publish("v0.2")
      status, _, error = self_update
      status.should eq 1
      error.should contain "was built from source"
      registry.fetched.should be_empty
    end
  end

  {% unless flag?(:win32) %}
    it "leaves a binary a package manager installed to that package manager" do
      with_cli_releases do |registry|
        cellar = registry.dir / "Cellar" / "zane" / "bin"
        Dir.mkdir_p(cellar)
        File.write(cellar / "zane", "brewed zane")
        File.delete(registry.executable)
        File.symlink(cellar / "zane", registry.executable)
        registry.publish("v0.2")
        status, _, error = self_update
        status.should eq 1
        error.should contain "was installed by Homebrew; update zane with Homebrew instead"
        File.read(cellar / "zane").should eq "brewed zane"
      end
    end

    it "checks that the new binary reports the release it was downloaded as" do
      dir = Path[Dir.tempdir] / "zane-check-#{Random::Secure.hex(8)}"
      Dir.mkdir(dir)
      begin
        File.write(dir / "zane", "#!/bin/sh\necho zane v0.2\n")
        File.chmod(dir / "zane", 0o755)
        Zane::SelfUpdate.check_runs(dir / "zane", "v0.2")
        expect_raises(Zane::UserError, "reports `zane v0.2`") { Zane::SelfUpdate.check_runs(dir / "zane", "v0.3") }
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  {% end %}

  it "deletes only the binaries an update set aside" do
    with_cli_releases do |registry|
      bin = registry.dir / "bin"
      File.write(bin / "#{Zane::SelfUpdate::OLD_PREFIX}0123.exe", "old")
      File.write(bin / "other", "kept")
      Zane::SelfUpdate.clean_old(bin)
      Dir.children(bin).sort.should eq ["other", "zane"]
    end
  end

  it "is reached through `zane self update`, which takes at most a version" do
    output, error = IO::Memory.new, IO::Memory.new
    Zane::CLI.run(["self"], output, error).should eq 1
    error.to_s.should contain Zane::Commands::SelfCommand::USAGE
    Zane::CLI.run(["self", "update", "v0.1", "v0.2"], output, error).should eq 1
    Zane::CLI.run(["help"], output, error)
    output.to_s.should contain "self update [version]"
  end
end
