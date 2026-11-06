require "json"
require "./archive"
require "./errors"
require "./progress"
require "./sha256"
require "./version"

module Zane
  # Replaces the running `zane` with a published release of the CLI, as the
  # installers do (docs/design/cli.md §4.2).
  module SelfUpdate
    URL = "https://github.com/zane-lang/zane"
    API = "https://api.github.com/repos/zane-lang/zane/releases"
    TAG = /\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?\z/

    # Where Windows leaves the binary it replaced, until the next run deletes it.
    OLD_PREFIX = ".zane-old-"

    # Specs replace the binary being updated, the version it reports, and the
    # check that a downloaded binary runs.
    class_property executable : Proc(Path) = -> {
      Path[Process.executable_path || raise UserError.new("cannot find the zane executable to update")]
    }
    class_property current : String = VERSION
    class_property check : Proc(Path, String, Nil) = ->(binary : Path, tag : String) { check_runs(binary, tag) }

    # The release asset built for this host, or nil where none is published.
    def self.asset : String?
      {% if flag?(:win32) && flag?(:x86_64) %}
        "zane-windows-x86_64.exe"
      {% elsif flag?(:darwin) && flag?(:aarch64) %}
        "zane-macos-arm64"
      {% elsif flag?(:linux) && flag?(:x86_64) %}
        "zane-linux-x86_64"
      {% else %}
        nil
      {% end %}
    end

    # The components of a CLI tag, a missing patch counting as 0, or nil when
    # *tag* is not one.
    def self.version(tag : String) : Array(Int32)?
      return unless match = TAG.match(tag)
      [match[1].to_i, match[2].to_i, (match[3]? || "0").to_i]
    end

    # What an update did to the binary at *path*: installed *tag*, found it
    # already is *tag*, or found it newer than the latest release, *tag*. The
    # path is found before the update, since afterwards the running process's
    # own file is gone.
    record Result, tag : String, outcome : Outcome, path : Path
    enum Outcome
      Installed
      Current
      Newer
    end

    # Installs the release *tag*, or else the latest one when it is newer than
    # this binary, over the running executable.
    def self.run(tag : String? = nil, asset : String? = self.asset,
                 progress : Progress = Progress.current) : Result
      if tag && !version(tag)
        raise UserError.new("`#{tag}` is not a zane version; use vMAJOR.MINOR or vMAJOR.MINOR.PATCH, such as v0.1")
      end
      raise UserError.new("no zane release is built for this platform; build zane from source") unless asset
      target = executable.call
      check_installed_by_installer(target)
      installed = version(@@current)
      raise UserError.new("this zane (#{@@current}) was built from source, not installed from a release; " \
                          "rebuild it, or install a release with install.sh or install.ps1") unless installed

      staging = target.parent / ".zane-update-#{Random::Secure.hex(8)}"
      begin
        Dir.mkdir(staging)
      rescue File::AccessDeniedError
        staging = nil
        raise UserError.new("cannot write to #{target.parent}, where zane is installed; " \
                            "run the update as the user that installed it")
      end
      progress.step(tag ? "Looking up zane #{tag}" : "Looking up the latest zane release")
      metadata = staging / "release.json"
      Archive.download.call(tag ? "#{API}/tags/#{tag}" : "#{API}/latest", metadata)
      release = JSON.parse(File.read(metadata))
      published = release["tag_name"].as_s
      raise UserError.new("the zane release has the invalid tag `#{published}`") unless version(published)
      raise UserError.new("the zane release returned #{published} instead of #{tag}") if tag && tag != published
      raise UserError.new("#{published} is a draft zane release") if release["draft"]?.try(&.as_bool)
      assets = release["assets"].as_a.map { |a| a["name"].as_s }
      unless assets.includes?(asset) && assets.includes?("SHA256SUMS")
        raise UserError.new("zane #{published} has no #{asset} and checksums; choose another release")
      end
      progress.done("Found zane #{published}")
      # v0.2 and v0.2.0 are one release, so versions compare as numbers.
      latest = version(published).not_nil!
      return Result.new(published, Outcome::Current, target) if latest == installed
      return Result.new(published, Outcome::Newer, target) if !tag && latest < installed

      base = "#{URL}/releases/download/#{published}"
      sums = staging / "SHA256SUMS"
      progress.step("Downloading checksums")
      Archive.download.call("#{base}/SHA256SUMS", sums)
      digest = SHA256.listed(File.read(sums), asset)
      progress.done("Downloaded checksums")
      binary = staging / target.basename
      size = release["assets"].as_a.find { |a| a["name"].as_s == asset }.try(&.["size"]?).try(&.as_i64?)
      progress.step("Downloading zane #{published}", size) { File.info?(binary).try(&.size) || 0_i64 }
      Archive.download.call("#{base}/#{asset}", binary)
      progress.done("Downloaded #{asset}")
      hashed = Atomic(Int64).new(0)
      progress.step("Verifying SHA-256", File.size(binary)) { hashed.get }
      unless SHA256.file(binary, ->(n : Int32) { hashed.add(n.to_i64); nil }) == digest
        raise UserError.new("checksum mismatch for zane #{published}; nothing was installed")
      end
      progress.done("Binary matches its SHA-256 #{digest[0, 12]}", amount: false)
      File.chmod(binary, 0o755)
      progress.step("Checking the new binary")
      check.call(binary, published)
      progress.done("The new binary is zane #{published}")
      progress.step("Installing zane #{published}")
      replace(binary, target)
      progress.done("Installed zane #{published}")
      Result.new(published, Outcome::Installed, target)
    rescue error : JSON::ParseException | TypeCastError | KeyError
      raise UserError.new("invalid zane release metadata: #{error.message}")
    rescue error : File::Error
      raise UserError.new("cannot update zane: #{error.message}")
    ensure
      FileUtils.rm_rf(staging) if staging && Dir.exists?(staging)
    end

    # Deletes the binaries an update on Windows set aside, which can only go
    # once they no longer run. Elsewhere there are none.
    def self.clean_old(dir : Path) : Nil
      Dir.each_child(dir) do |name|
        next unless name.starts_with?(OLD_PREFIX)
        begin
          File.delete?(dir / name)
        rescue File::Error
        end
      end
    rescue File::Error
    end

    # A package manager owns the files it installs and replaces them itself,
    # so an update that overwrote them would be undone or break its records.
    private def self.check_installed_by_installer(target : Path) : Nil
      path = (File.realpath(target) rescue target.to_s).gsub('\\', '/')
      return unless manager = package_manager(path)
      raise UserError.new("#{path} was installed by #{manager}; update zane with #{manager} instead")
    end

    # The package manager that owns the file at the real path *path*, if any.
    def self.package_manager(path : String) : String?
      if path.starts_with?("/nix/store/")
        "Nix"
      elsif path.includes?("/Cellar/")
        "Homebrew"
      end
    end

    # The binary must start on this machine and be the release it claims.
    def self.check_runs(binary : Path, tag : String) : Nil
      output = IO::Memory.new
      status = begin
        Process.run(binary.to_s, ["--version"], output: output, error: IO::Memory.new)
      rescue error : IO::Error | File::Error
        raise UserError.new("the downloaded zane #{tag} does not run here: #{error.message}; nothing was installed")
      end
      unless status.success? && output.to_s.strip == "zane #{tag}"
        raise UserError.new("the downloaded zane #{tag} reports `#{output.to_s.strip}`; nothing was installed")
      end
    end

    # Puts *binary* at *target* in one rename on the same filesystem, so an
    # interrupted update leaves the old binary or the new, never part of one.
    # Windows will not replace a running executable but will rename it, so it
    # is moved aside first and deleted by a later run.
    private def self.replace(binary : Path, target : Path) : Nil
      {% if flag?(:win32) %}
        old = target.parent / "#{OLD_PREFIX}#{Random::Secure.hex(8)}.exe"
        File.rename(target, old)
        begin
          File.rename(binary, target)
        rescue error
          File.rename(old, target)
          raise error
        end
        begin
          File.delete?(old)
        rescue File::Error
          # It is this process's own executable; clean_old deletes it later.
        end
      {% else %}
        File.rename(binary, target)
      {% end %}
    end
  end
end
