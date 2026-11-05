require "json"
require "./archive"
require "./compiler"
require "./compiler_release"
require "./home"
require "./progress"

module Zane::Toolchain
  API = "https://api.github.com/repos/zane-lang/compiler/releases"

  # Specs replace the Git lookup, just as they replace Archive.download.
  class_property resolve : Proc(String, CompilerRelease) = ->(tag : String) { CompilerRelease.resolve(tag) }
  # And the listing of the release tags.
  class_property releases : Proc(Array(String)) = -> { CompilerRelease.listed.keys }

  def self.host : String
    {% if flag?(:win32) %}
      "windows-x86_64"
    {% elsif flag?(:darwin) %}
      "macos-{{ (flag?(:aarch64) ? "arm64" : "x86_64").id }}"
    {% elsif flag?(:linux) %}
      "linux-{{ (flag?(:aarch64) ? "arm64" : "x86_64").id }}"
    {% else %}
      raise UserError.new("compiler toolchain installation is not supported on this operating system")
    {% end %}
  end

  # Uses the latest published release by default, even when an older compiler
  # is installed or the current project pins another version. *vet* sees the
  # release and the commit its tag points to before anything is downloaded,
  # and refuses it by raising. *progress* is told each step as it happens.
  def self.install(tag : String? = nil, dir : Path = Home.toolchains,
                   platform : String = host, vet : (CompilerRelease -> Nil)? = nil,
                   progress : Progress = Progress.current) : CompilerRelease
    staging_created = false
    validate_tag(tag) if tag
    Dir.mkdir_p(dir)
    staging = dir / ".install-#{Random::Secure.hex(8)}"
    Dir.mkdir(staging)
    staging_created = true
    metadata = staging / "release.json"
    progress.step(tag ? "Looking up compiler #{tag}" : "Looking up the latest compiler release")
    Archive.download.call(tag ? "#{API}/tags/#{tag}" : "#{API}/latest", metadata)
    release = JSON.parse(File.read(metadata))
    published_tag = release["tag_name"].as_s
    validate_tag(published_tag)
    if tag && tag != published_tag
      raise UserError.new("the compiler release returned #{published_tag} instead of #{tag}")
    end
    raise UserError.new("#{published_tag} is a draft compiler release") if release["draft"]?.try(&.as_bool)
    asset = "zane-compiler-#{published_tag}-#{platform}.tar.gz"
    assets = release["assets"].as_a.map { |a| a["name"].as_s }
    unless assets.includes?(asset) && assets.includes?("SHA256SUMS")
      raise UserError.new("compiler #{published_tag} has no toolchain archive and checksums for #{platform}; " \
                          "choose a release with that host platform, or build zanec from source")
    end
    progress.done("Found compiler #{published_tag} for #{platform}")
    progress.step("Resolving the commit of #{published_tag}")
    compiler = resolve.call(published_tag)
    progress.done("Compiler #{published_tag} is commit #{compiler.commit[0, 12]}")
    vet.try &.call(compiler)
    destination = dir / published_tag
    if File.exists?(destination) || File.symlink?(destination)
      unless File.symlink?(destination) || !executable?(destination / "bin" / Compiler::EXECUTABLE) ||
             !File.file?(destination / CompilerRelease::RECORD)
        from, commit = CompilerRelease.read_record(destination / CompilerRelease::RECORD)
        if from == CompilerRelease::URL && commit == compiler.commit
          progress.note("Compiler #{published_tag} is already installed in #{destination}")
          return CompilerRelease.new(published_tag, compiler.commit, true)
        end
      end
      raise UserError.new("#{destination} already exists but is not this complete compiler release; " \
                          "move it aside before installing #{published_tag}")
    end
    base = "#{CompilerRelease::URL}/releases/download/#{published_tag}"
    sums = staging / "SHA256SUMS"
    progress.step("Downloading checksums")
    Archive.download.call("#{base}/SHA256SUMS", sums)
    digest = checksum(File.read(sums), asset)
    progress.done("Downloaded checksums")
    archive = staging / asset
    size = release["assets"].as_a.find { |a| a["name"].as_s == asset }.try(&.["size"]?).try(&.as_i64?)
    progress.step("Downloading compiler #{published_tag}", size) { File.info?(archive).try(&.size) || 0_i64 }
    Archive.download.call("#{base}/#{asset}", archive)
    progress.done("Downloaded #{asset}")
    # The counters are read by the thread that draws the progress.
    hashed = Atomic(Int64).new(0)
    progress.step("Verifying SHA-256", File.size(archive)) { hashed.get }
    unless SHA256.file(archive, ->(n : Int32) { hashed.add(n.to_i64); nil }) == digest
      raise UserError.new("checksum mismatch for compiler #{published_tag}; the toolchain was not installed")
    end
    progress.done("Archive matches its SHA-256 #{digest[0, 12]}", amount: false)
    extracted = staging / "toolchain"
    unpacked = Atomic(Int64).new(0)
    progress.step("Extracting the archive", File.size(archive)) { unpacked.get }
    files = Archive.extract(archive, extracted, root: asset.rchop(".tar.gz"), strip_root: true,
      executable_modes: true, read: ->(n : Int32) { unpacked.add(n.to_i64); nil })
    progress.done("Extracted #{files} files", amount: false)
    progress.step("Checking the toolchain")
    unless executable?(extracted / "bin" / Compiler::EXECUTABLE) &&
           File.file?(extracted / "VERSION") && File.read(extracted / "VERSION").strip == published_tag
      raise UserError.new("compiler #{published_tag} archive is missing its executable or has the wrong version")
    end
    from, commit = CompilerRelease.read_record(extracted / CompilerRelease::RECORD)
    unless from == CompilerRelease::URL && commit == compiler.commit
      raise UserError.new("compiler #{published_tag} archive's toolchain record does not match its release tag")
    end
    progress.done("Toolchain is #{published_tag} at commit #{compiler.commit[0, 12]}")
    # The complete directory becomes visible at once, on the same filesystem.
    raise UserError.new("#{destination} appeared during installation; retry the command") if File.exists?(destination) || File.symlink?(destination)
    progress.step("Installing compiler #{published_tag}")
    File.rename(extracted, destination)
    progress.done("Installed compiler #{published_tag}")
    CompilerRelease.new(published_tag, compiler.commit, true)
  rescue error : JSON::ParseException | TypeCastError | KeyError
    raise UserError.new("invalid compiler release metadata: #{error.message}")
  rescue error : File::Error
    raise UserError.new("cannot install the compiler toolchain: #{error.message}")
  ensure
    FileUtils.rm_rf(staging) if staging_created && staging && Dir.exists?(staging)
  end

  private def self.validate_tag(tag : String) : Nil
    unless /\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z/.matches?(tag)
      raise UserError.new("`#{tag}` is not a compiler version; use vMAJOR.MINOR, such as v3.0")
    end
  end

  private def self.executable?(path : Path) : Bool
    {% if flag?(:win32) %}
      File.file?(path)
    {% else %}
      File.file?(path) && File::Info.executable?(path)
    {% end %}
  end

  private def self.checksum(text : String, asset : String) : String
    matches = text.lines.compact_map do |line|
      if match = /\A([0-9a-fA-F]{64})[ \t]+\*?#{Regex.escape(asset)}\z/.match(line)
        match[1].downcase
      end
    end
    raise UserError.new("SHA256SUMS must contain exactly one valid checksum for #{asset}") unless matches.size == 1
    matches.first
  end
end
