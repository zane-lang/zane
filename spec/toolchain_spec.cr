require "./spec_helper"

private def toolchain_archive(entries : Array({String, Char, String, Int32})) : Bytes
  tar = IO::Memory.new
  entries.each do |name, type, text, mode|
    header = Bytes.new(512)
    name.to_slice.copy_to(header)
    (mode.to_s(8).rjust(7, '0') + "\0").to_slice.copy_to(header[100, 8])
    (text.bytesize.to_s(8).rjust(11, '0') + "\0").to_slice.copy_to(header[124, 12])
    header[156] = type.ord.to_u8
    "ustar\0".to_slice.copy_to(header[257, 6])
    "        ".to_slice.copy_to(header[148, 8])
    (header.sum(0) { |b| b.to_i }.to_s(8).rjust(6, '0') + "\0 ").to_slice.copy_to(header[148, 8])
    tar.write(header)
    tar.write(text.to_slice)
    tar.write(Bytes.new((512 - text.bytesize % 512) % 512))
  end
  tar.write(Bytes.new(1024))
  gzip = IO::Memory.new
  Compress::Gzip::Writer.open(gzip) { |writer| writer.write(tar.to_slice) }
  gzip.to_slice
end

private class ToolchainRegistry
  getter dir : Path
  getter downloads = {} of String => Bytes
  getter commits = {} of String => String
  getter fetched = [] of String

  def initialize
    @dir = Path[Dir.tempdir] / "zane-toolchains-#{Random::Secure.hex(8)}"
    Dir.mkdir(@dir)
  end

  def asset(tag : String, platform : String = Zane::Toolchain.host) : String
    "zane-compiler-#{tag}-#{platform}.tar.gz"
  end

  def base(tag : String) : String
    "#{Zane::CompilerRelease::URL}/releases/download/#{tag}"
  end

  def entries(tag : String, commit : String = "a" * 40) : Array({String, Char, String, Int32})
    root = asset(tag).rchop(".tar.gz")
    [
      {"#{root}/", '5', "", 0o755},
      {"#{root}/bin/#{Zane::Compiler::EXECUTABLE}", '0', "compiler", 0o4755},
      {"#{root}/VERSION", '0', "#{tag}\n", 0o644},
      {"#{root}/toolchain.coda", '0', "url #{Zane::CompilerRelease::URL}\ncommit #{commit}\n", 0o644},
      {"#{root}/zig/zig", '0', "zig", 0o755},
    ]
  end

  def publish(tag : String, commit : String = "a" * 40, archive : Bytes? = nil) : Nil
    @commits[tag] = commit
    name = asset(tag)
    bytes = archive || toolchain_archive(entries(tag, commit))
    @downloads["#{base(tag)}/#{name}"] = bytes
    @downloads["#{base(tag)}/SHA256SUMS"] = "#{Zane::SHA256.hexdigest(bytes)}  #{name}\n".to_slice
    metadata(tag, [name, "SHA256SUMS"])
  end

  def metadata(tag : String, assets : Array(String)) : Nil
    json = {"tag_name" => tag, "draft" => false, "assets" => assets.map { |name| {"name" => name} }}.to_json
    @downloads["#{Zane::Toolchain::API}/latest"] = json.to_slice
    @downloads["#{Zane::Toolchain::API}/tags/#{tag}"] = json.to_slice
  end
end

private def with_toolchains(&)
  registry = ToolchainRegistry.new
  home = ENV["ZANE_HOME"]?
  ENV["ZANE_HOME"] = registry.dir.to_s
  download, resolve = Zane::Archive.download, Zane::Toolchain.resolve
  Zane::Archive.download = ->(url : String, path : Path) {
    registry.fetched << url
    File.write(path, registry.downloads[url]? || raise Zane::UserError.new("404 #{url}"))
    nil
  }
  Zane::Toolchain.resolve = ->(tag : String) { Zane::CompilerRelease.new(tag, registry.commits[tag]) }
  begin
    yield registry
  ensure
    Zane::Archive.download, Zane::Toolchain.resolve = download, resolve
    home ? (ENV["ZANE_HOME"] = home) : ENV.delete("ZANE_HOME")
    FileUtils.rm_rf(registry.dir)
  end
end

private def toolchain_command(*args : String) : {Int32, String, String}
  toolchain_command(args.to_a)
end

private def toolchain_command(args : Array(String)) : {Int32, String, String}
  output, error = IO::Memory.new, IO::Memory.new
  status = Zane::CLI.run(["toolchain"] + args, output, error)
  {status, output.to_s, error.to_s}
end

describe Zane::Toolchain do
  it "installs latest outside a project and makes it discoverable by the compiler locator" do
    with_toolchains do |registry|
      registry.publish("v1.0")
      toolchain_command("install")[0].should eq 0
      dir = Zane::Home.toolchains / "v1.0"
      File.read(dir / "VERSION").should eq "v1.0\n"
      Zane::CompilerRelease.installed(Zane::Home.toolchains)["v1.0"].should eq "a" * 40
      {% unless flag?(:win32) %}
        File.info(dir / "bin/zanec").permissions.value.should eq 0o755
        File.info(dir / "zig/zig").permissions.value.should eq 0o755
      {% end %}
      saved = ENV["ZANE_COMPILER"]?
      ENV.delete("ZANE_COMPILER")
      begin
        Zane::Compiler.locate("v1.0").path.should eq((dir / "bin" / Zane::Compiler::EXECUTABLE).to_s)
      ensure
        saved ? (ENV["ZANE_COMPILER"] = saved) : ENV.delete("ZANE_COMPILER")
      end
      registry.fetched.first.should eq "#{Zane::Toolchain::API}/latest"
      Dir.children(Zane::Home.toolchains).should eq ["v1.0"]
    end
  end

  it "installs a specified older version alongside latest, and reuses a matching installation" do
    with_toolchains do |registry|
      registry.publish("v1.0")
      registry.publish("v3.0", "b" * 40)
      toolchain_command("install")[0].should eq 0
      toolchain_command("install", "v1.0")[0].should eq 0
      before = registry.fetched.size
      toolchain_command("install", "v1.0")[0].should eq 0
      registry.fetched[before..].should eq ["#{Zane::Toolchain::API}/tags/v1.0"]
      Zane::CompilerRelease.installed(Zane::Home.toolchains).keys.sort.should eq ["v1.0", "v3.0"]
    end
  end

  it "checks published latest even when an older version is already installed" do
    with_toolchains do |registry|
      registry.publish("v1.0")
      toolchain_command("install")[0].should eq 0
      registry.publish("v3.0")
      toolchain_command("install")[1].should contain "v3.0"
    end
  end

  it "rejects bad arguments and versions before contacting a release server" do
    with_toolchains do |registry|
      [[] of String, ["use", "v1.0"], ["install", "v1.0", "extra"], ["install", "../v1.0"],
       ["install", "v1.0.0"], ["install", "v01.0"]].each do |args|
        toolchain_command(args)[0].should eq 1
      end
      registry.fetched.should be_empty
    end
  end

  it "reports releases without assets for the current host" do
    with_toolchains do |registry|
      registry.metadata("v1.0", ["zane-compiler-v1.0-another-host.tar.gz", "SHA256SUMS"])
      status, _, error = toolchain_command("install")
      status.should eq 1
      error.should contain "no toolchain archive"
      Dir.children(Zane::Home.toolchains).should be_empty
    end
  end

  it "rejects checksum mismatches, missing and duplicate entries, and download failures" do
    with_toolchains do |registry|
      ["corrupt", "missing", "duplicate", "download"].each do |failure|
        registry.publish("v1.0")
        url = "#{registry.base("v1.0")}/#{registry.asset("v1.0")}"
        sums = "#{registry.base("v1.0")}/SHA256SUMS"
        case failure
        when "corrupt"   then registry.downloads[url] = "corrupt".to_slice
        when "missing"   then registry.downloads[sums] = "bad checksum\n".to_slice
        when "duplicate" then registry.downloads[sums] = (String.new(registry.downloads[sums]) * 2).to_slice
        when "download"  then registry.downloads.delete(url)
        end
        toolchain_command("install")[0].should eq 1
        Dir.children(Zane::Home.toolchains).should be_empty
      end
    end
  end

  it "rejects archives whose record or version disagrees with the published tag" do
    with_toolchains do |registry|
      registry.publish("v1.0", "a" * 40, toolchain_archive(registry.entries("v1.0", "b" * 40)))
      toolchain_command("install")[2].should contain "record does not match"
      entries = registry.entries("v1.0").map do |name, type, text, mode|
        {name, type, name.ends_with?("/VERSION") ? "v3.0\n" : text, mode}
      end
      registry.publish("v1.0", archive: toolchain_archive(entries))
      toolchain_command("install")[2].should contain "wrong version"
      registry.publish("v1.0", "a" * 40, toolchain_archive(registry.entries("v3.0")))
      toolchain_command("install")[0].should eq 1
      Dir.children(Zane::Home.toolchains).should be_empty
    end
  end

  it "reads the pax long paths used by the compiler release packager" do
    with_toolchains do |registry|
      root = registry.asset("v1.0").rchop(".tar.gz")
      # Exceed tar's 100-byte name field while keeping the extraction path
      # below Windows' legacy filesystem path limit in its longer temp dir.
      name = "#{root}/zig/lib/" + "long/" * 15 + "source.h"
      name.bytesize.should be > 100
      data = "path=#{name}\n"
      length = data.bytesize + 4
      loop do
        actual = data.bytesize + length.to_s.bytesize + 1
        break if actual == length
        length = actual
      end
      entries = registry.entries("v1.0") + [
        {"PaxHeaders/source.h", 'x', "#{length} #{data}", 0o644},
        {"placeholder", '0', "long path", 0o644},
      ]
      registry.publish("v1.0", archive: toolchain_archive(entries))
      status, _, error = toolchain_command("install")
      error.should eq ""
      status.should eq 0
      File.read(Zane::Home.toolchains / "v1.0" / name.lchop("#{root}/")).should eq "long path"
    end
  end

  it "rejects inconsistent release metadata and leaves no staged directory" do
    with_toolchains do |registry|
      registry.publish("v1.0")
      ["not json", {"tag_name" => "../../escape", "assets" => [] of String}.to_json,
       {"tag_name" => "v3.0", "assets" => [] of String}.to_json].each do |data|
        registry.downloads["#{Zane::Toolchain::API}/tags/v1.0"] = data.to_slice
        toolchain_command("install", "v1.0")[0].should eq 1
        Dir.children(Zane::Home.toolchains).should be_empty
      end
    end
  end

  it "refuses unsafe paths and links without leaving a partially installed toolchain" do
    with_toolchains do |registry|
      root = registry.asset("v1.0").rchop(".tar.gz")
      [{"#{root}/../outside", '0'}, {"/outside", '0'}, {"#{root}/bin/link", '2'},
       {"#{root}/bin/hard", '1'}, {"#{root}/bin/..\\evil", '0'}].each do |name, type|
        entries = registry.entries("v1.0") + [{name, type, "unsafe", 0o755}]
        registry.publish("v1.0", archive: toolchain_archive(entries))
        toolchain_command("install")[0].should eq 1
        Dir.children(Zane::Home.toolchains).should be_empty
        File.exists?(registry.dir / "outside").should be_false
      end
    end
  end

  it "preserves an existing incomplete or conflicting directory" do
    with_toolchains do |registry|
      registry.publish("v1.0")
      dir = Zane::Home.toolchains / "v1.0"
      Dir.mkdir_p(dir)
      File.write(dir / "keep", "untouched")
      toolchain_command("install")[2].should contain "already exists"
      File.read(dir / "keep").should eq "untouched"
      Dir.children(Zane::Home.toolchains).should eq ["v1.0"]
    end
  end

  it "preserves an installed release if the repository tag now names a different commit" do
    with_toolchains do |registry|
      registry.publish("v1.0")
      toolchain_command("install")[0].should eq 0
      registry.publish("v1.0", "b" * 40)
      toolchain_command("install")[0].should eq 1
      Zane::CompilerRelease.installed(Zane::Home.toolchains)["v1.0"].should eq "a" * 40
    end
  end

  {% unless flag?(:win32) %}
    it "refuses an archive whose compiler has no executable bits" do
      with_toolchains do |registry|
        entries = registry.entries("v1.0").map do |name, type, text, mode|
          {name, type, text, name.ends_with?("/bin/zanec") ? 0o644 : mode}
        end
        registry.publish("v1.0", archive: toolchain_archive(entries))
        toolchain_command("install")[0].should eq 1
        Dir.children(Zane::Home.toolchains).should be_empty
      end
    end
  {% end %}
end
