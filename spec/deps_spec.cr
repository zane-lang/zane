require "./spec_helper"
require "compress/gzip"

# Builds a tar archive of *entries*, each a path, a type flag and contents,
# gzip-compressed, the way `tar czf` writes one.
private def tar_gz(entries : Array({String, Char, String})) : Bytes
  tar = IO::Memory.new
  entries.each do |name, type, contents|
    header = Bytes.new(512)
    name.to_slice.copy_to(header)
    "0000644\0".to_slice.copy_to(header[100, 8])
    (contents.bytesize.to_s(8).rjust(11, '0') + "\0").to_slice.copy_to(header[124, 12])
    header[156] = type.ord.to_u8
    "ustar\0".to_slice.copy_to(header[257, 6])
    "00".to_slice.copy_to(header[263, 2])
    "        ".to_slice.copy_to(header[148, 8])
    sum = header.sum(0) { |b| b.to_i }
    (sum.to_s(8).rjust(6, '0') + "\0 ").to_slice.copy_to(header[148, 8])
    tar.write(header)
    tar.write(contents.to_slice)
    tar.write(Bytes.new((512 - contents.bytesize % 512) % 512))
  end
  tar.write(Bytes.new(1024))
  gz = IO::Memory.new
  Compress::Gzip::Writer.open(gz) { |w| w.write(tar.to_slice) }
  gz.to_slice
end

private def git(dir : Path, *args : String) : String
  output = IO::Memory.new
  status = Process.run("git", ["-C", dir.to_s, "-c", "user.name=spec", "-c", "user.email=spec@example.com"] + args.to_a,
    output: output, error: Process::Redirect::Inherit)
  raise "git #{args.join(" ")} failed" unless status.success?
  output.to_s.strip
end

# Libraries published as git repositories in a temporary directory. git
# reaches each at `https://example.com/<name>` through `insteadOf`, and its
# archive is downloaded from the files this keeps, so nothing goes online.
private class Registry
  getter dir : Path
  getter downloads = {} of String => Path
  getter fetched = [] of String

  def initialize(@dir : Path)
  end

  def url(name : String) : String
    "https://example.com/#{name}"
  end

  def stamp(name : String, tag : String) : String
    Zane::PackageUrl.parse(url(name)).stamp(tag)
  end

  # Publishes *name* at *tag*, depending on *deps* (each a name and tag
  # published before), and returns the tag's commit.
  def publish(name : String, tag : String, deps = [] of {String, String}, kind = "library",
              archive : Bytes? = nil, artifacts = true, package_name = name) : String
    repo = @dir / name
    unless Dir.exists?(repo)
      Dir.mkdir_p(repo)
      git(repo, "init", "-q")
    end
    Dir.mkdir_p(repo / "src")
    File.write(repo / "src" / "#{name}.zn", "package #{package_name};\n")
    File.write(repo / "zane.coda", <<-CODA)
      name #{package_name}
      kind #{kind}
      zane-version v0.1
      version-pattern v*.+.++

      deps [
          key version from
      #{deps.map { |d, t| "    #{d} #{t} release\n" }.join}]
      CODA
    rows = deps.map { |d, t| "    #{d} #{url(d)} #{git(@dir / d, "rev-parse", "#{t}^{commit}")}\n" }.join
    File.write(repo / "zane-lock.coda", <<-CODA)
      resolutions [
          key url commit
          zane https://github.com/zane-lang/compiler 0123456789abcdef0123456789abcdef01234567
      #{rows}]
      CODA
    if artifacts
      bytes = archive || tar_gz([{"build/", '5', ""}, {"build/#{name}.o", '0', "object #{name} #{tag}"}])
      file = @dir / "#{name}-#{tag}.tar.gz"
      File.write(file, bytes)
      download = "https://downloads.example.com/#{name}-#{tag}.tar.gz"
      @downloads[download] = file
      File.write(repo / "zane-artifacts.coda", <<-CODA)
        artifacts [
            target url sha256
            #{Zane::Target::HOST} #{download} #{Zane::SHA256.hexdigest(bytes)}
        ]
        CODA
    end
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "#{name} #{tag}")
    git(repo, "tag", tag)
    git(repo, "rev-parse", "HEAD")
  end
end

DEPS_ENV = %w(ZANE_COMPILER FAKE_ZANEC_LOG GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0)

private def with_registry(&)
  base = Path[File.join(Dir.tempdir, "zane-spec-deps-#{Random::Secure.hex(6)}")]
  registry = Registry.new(base / "repos")
  project = base / "project"
  Dir.mkdir_p(registry.dir)
  Dir.mkdir_p(project / "src")
  File.write(project / "zane.coda", "name app\nkind application\nzane-version v0.1\nversion-pattern v*.+.++\n\ndeps [\n    key version from\n]\n")
  File.write(project / "zane-lock.coda", "resolutions [\n    key url commit\n    zane https://github.com/zane-lang/compiler 0123456789abcdef0123456789abcdef01234567\n]\n")
  File.write(project / "src" / "main.zn", "package app;\n")
  saved = DEPS_ENV.to_h { |v| {v, ENV[v]?} }
  ENV["ZANE_COMPILER"] = DEPS_ZANEC
  ENV["FAKE_ZANEC_LOG"] = (base / "zanec.log").to_s
  ENV["GIT_CONFIG_COUNT"] = "1"
  ENV["GIT_CONFIG_KEY_0"] = "url.#{registry.dir.to_posix}/.insteadOf"
  ENV["GIT_CONFIG_VALUE_0"] = "https://example.com/"
  downloader = Zane::Archive.download
  Zane::Archive.download = ->(url : String, path : Path) {
    registry.fetched << url
    File.copy(registry.downloads[url]? || raise(Zane::UserError.new("404 #{url}")), path)
    nil
  }
  begin
    yield registry, project, base / "zanec.log"
  ensure
    Zane::Archive.download = downloader
    saved.each { |v, value| value ? (ENV[v] = value) : ENV.delete(v) }
    FileUtils.rm_rf(base)
    FileUtils.rm_rf(Zane::Home.packages)
  end
end

private def zane(args : Array(String), dir : Path) : {Int32, String, String}
  output, error = IO::Memory.new, IO::Memory.new
  command = args.first
  rest = args[1..]
  status = case command
           when "add"   then Zane::Commands::Add.new(rest, output, error, dir).run
           when "fetch" then Zane::Commands::Fetch.new(rest, output, error, dir).run
           when "build" then Zane::Commands::Build.new(rest, output, error, dir).run
           when "check" then Zane::Commands::Check.new(rest, output, error, dir).run
           else              raise "no command #{command}"
           end
  {status, output.to_s, error.to_s}
end

DEPS_ZANEC = begin
  path = File.join(Dir.tempdir, "zane-spec-deps-zanec-#{Process.pid}#{{{ flag?(:win32) ? ".exe" : "" }}}")
  status = Process.run("crystal", ["build", "spec/support/fake_zanec.cr", "-o", path], error: Process::Redirect::Inherit)
  raise "cannot build the fake compiler" unless status.success?
  path
end

private def entry(name : String, tag : String) : Path
  Zane::Home.packages / "example.com" / name / tag
end

describe Zane::PackageUrl do
  it "gives every spelling of one repository one identity" do
    https = Zane::PackageUrl.parse("https://github.com/zane-lang/math")
    https.normalized.should eq "github.com/zane-lang/math"
    Zane::PackageUrl.parse("git@github.com:zane-lang/math").normalized.should eq https.normalized
    Zane::PackageUrl.parse("ssh://git@github.com/zane-lang/math/").normalized.should eq https.normalized
    https.identity_hash.should eq Zane::SHA256.hexdigest("github.com/zane-lang/math")[0, 16]
    https.stamp("v1.0.1").should eq "v1.0.1%#{https.identity_hash}%"
    https.basename.should eq "math"
  end

  it "refuses a URL that cannot name directories as it is" do
    expect_raises(Zane::UserError, "is not a package URL") { Zane::PackageUrl.parse("https://example.com:8080/math") }
    expect_raises(Zane::UserError, "is not a package URL") { Zane::PackageUrl.parse("https://example.com/a/../math") }
    expect_raises(Zane::UserError, "is not a package URL") { Zane::PackageUrl.parse("https://example.com/m%41th") }
    Zane::PackageUrl.tag_error("v1.0%x").should_not be_nil
    Zane::PackageUrl.tag_error("v1.0.1").should be_nil
  end
end

describe Zane::Archive do
  it "unpacks the files under build/" do
    with_registry do |registry|
      archive = registry.dir / "a.tar.gz"
      File.write(archive, tar_gz([{"build/", '5', ""}, {"build/sub/a.o", '0', "aaa"}, {"build/b.o", '0', "b" * 600}]))
      dest = registry.dir / "out"
      Zane::Archive.extract(archive, dest).should eq 2
      File.read(dest / "build" / "sub" / "a.o").should eq "aaa"
      File.read(dest / "build" / "b.o").should eq "b" * 600
    end
  end

  it "refuses an entry that is not a file or directory under build/, and leaves nothing" do
    with_registry do |registry|
      {
        {"build/../evil", '0', "x"}  => "leaves the directory",
        {"/etc/evil", '0', "x"}      => "is an absolute path",
        {"build/link", '2', ""}      => "is a symbolic link",
        {"build/hard", '1', ""}      => "is a hard link",
        {"elsewhere/a.o", '0', "x"}  => "is outside build/",
        {"build/..\\evil", '0', "x"} => "leaves the directory",
        {"build/fifo", '6', ""}      => "is a special file",
      }.each do |bad, why|
        archive = registry.dir / "bad.tar.gz"
        File.write(archive, tar_gz([{"build/ok.o", '0', "fine"}, bad]))
        expect_raises(Zane::UserError, why) { Zane::Archive.extract(archive, registry.dir / "out") }
        Dir.exists?(registry.dir / "out").should be_false
        Dir.children(registry.dir).select(&.starts_with?(".out")).should be_empty
      end
    end
  end

  it "refuses an archive with no files" do
    with_registry do |registry|
      archive = registry.dir / "empty.tar.gz"
      File.write(archive, tar_gz([{"build/", '5', ""}]))
      expect_raises(Zane::UserError, "holds no files under build/") { Zane::Archive.extract(archive, registry.dir / "out") }
    end
  end
end

describe Zane::Commands::Add do
  it "pins the newest tag, fetches and rewrites its objects, and records it in both files" do
    with_registry do |registry, project, log|
      registry.publish("math", "v1.0")
      commit = registry.publish("math", "v1.2")
      status, output, _ = zane(["add", registry.url("math")], project)
      status.should eq 0
      output.should contain "Added math v1.2"
      output.should contain "import math"

      manifest = read_coda(project / "zane.coda")["deps"].as(Hash)
      manifest["rows"].should eq({"math" => {"version" => "v1.2", "from" => "release"}})
      lock = read_coda(project / "zane-lock.coda")["resolutions"].as(Hash)["rows"].as(Hash)
      lock["math"].should eq({"url" => registry.url("math"), "commit" => commit})

      stamp = registry.stamp("math", "v1.2")
      rewritten = entry("math", "v1.2") / "build" / Zane::Target::HOST / "math.o"
      File.read(rewritten).should eq "rewritten #{stamp}\nobject math v1.2"
      File.read(entry("math", "v1.2") / "artifacts" / Zane::Target::HOST / "build" / "math.o").should eq "object math v1.2"
      File.file?(entry("math", "v1.2") / "src" / "src" / "math.zn").should be_true
      File.read_lines(log).size.should eq 1
    end
  end

  it "links the dependency into a build, stamped, without fetching it again" do
    with_registry do |registry, project, log|
      registry.publish("math", "v1.0")
      zane(["add", registry.url("math"), "v1.0"], project)[0].should eq 0
      zane(["build"], project)[0].should eq 0
      math = entry("math", "v1.0")
      File.read_lines(log).last.should end_with(
        "--package app=#{project / "src"} --package math=#{math / "src" / "src"} " \
        "--stamp math=#{registry.stamp("math", "v1.0")} --link #{math / "build" / Zane::Target::HOST / "math.o"}")
      registry.fetched.size.should eq 1
      File.read_lines(log).count(&.starts_with?("--rewrite")).should eq 1
    end
  end

  it "fetches what a library depends on, which is linked too" do
    with_registry do |registry, project, log|
      registry.publish("math", "v1.0")
      registry.publish("shapes", "v2.0", deps: [{"math", "v1.0"}])
      zane(["add", registry.url("shapes")], project)[0].should eq 0
      registry.fetched.size.should eq 2
      zane(["check"], project)[0].should eq 0
      File.read_lines(log).last.should eq(
        "--check --kind application --package app=#{project / "src"} " \
        "--package shapes=#{entry("shapes", "v2.0") / "src" / "src"} --package math=#{entry("math", "v1.0") / "src" / "src"} " \
        "--stamp shapes=#{registry.stamp("shapes", "v2.0")} --stamp math=#{registry.stamp("math", "v1.0")}")
    end
  end

  it "compiles a library from source when asked, fetching no archive for it" do
    with_registry do |registry, project, log|
      registry.publish("math", "v1.0", artifacts: false)
      zane(["add", registry.url("math"), "--from-source"], project)[0].should eq 0
      read_coda(project / "zane.coda")["deps"].as(Hash)["rows"].should eq({"math" => {"version" => "v1.0", "from" => "source"}})
      zane(["build"], project)[0].should eq 0
      File.read_lines(log).last.should end_with "--package math=#{entry("math", "v1.0") / "src" / "src"}"
      registry.fetched.should be_empty
    end
  end

  it "compiles a path dependency with the project, and fetches what it depends on" do
    with_registry do |registry, project, log|
      registry.publish("math", "v1.0")
      commit = registry.publish("shapes", "v2.0", deps: [{"math", "v1.0"}])
      local = registry.dir / "shapes"
      File.write(project / "zane.coda", File.read(project / "zane.coda").sub("]", "    shapes v2.0 #{local.relative_to(project).to_posix}\n]"))
      File.write(project / "zane-lock.coda", File.read(project / "zane-lock.coda").sub(/\]\n\z/, "    shapes #{registry.url("shapes")} #{commit}\n]\n"))
      zane(["build"], project)[0].should eq 0
      File.read_lines(log).last.should end_with(
        "--package shapes=#{local / "src"} --package math=#{entry("math", "v1.0") / "src" / "src"} " \
        "--stamp math=#{registry.stamp("math", "v1.0")} --link #{entry("math", "v1.0") / "build" / Zane::Target::HOST / "math.o"}")
      Dir.exists?(entry("shapes", "v2.0")).should be_false
    end
  end

  it "refuses an archive whose hash is not the committed one, and writes nothing" do
    with_registry do |registry, project|
      registry.publish("math", "v1.0")
      File.write(registry.downloads.values.first, "tampered")
      expect_raises(Zane::UserError, "security error") { zane(["add", registry.url("math")], project) }
      read_coda(project / "zane.coda")["deps"].as(Hash)["rows"].should eq({} of String => Hash(String, String))
      Dir.exists?(entry("math", "v1.0") / "build").should be_false
    end
  end

  it "refuses an application, and a library without objects for the target" do
    with_registry do |registry, project|
      registry.publish("tool", "v1.0", kind: "application")
      expect_raises(Zane::UserError, "is an application") { zane(["add", registry.url("tool")], project) }
      registry.publish("bare", "v1.0", artifacts: false)
      expect_raises(Zane::UserError, "set its `from` to `source`") { zane(["add", registry.url("bare")], project) }
    end
  end

  it "refuses a key that is not the library's package name" do
    with_registry do |registry, project|
      registry.publish("math-lib", "v1.0", package_name: "math")
      expect_raises(Zane::UserError, "cannot be the key; choose one with --as") { zane(["add", registry.url("math-lib")], project) }
      expect_raises(Zane::UserError, "is the package `math`") { zane(["add", registry.url("math-lib"), "--as", "maths"], project) }
      zane(["add", registry.url("math-lib"), "--as", "math"], project)[0].should eq 0
      expect_raises(Zane::UserError, "already depends on `math`") { zane(["add", registry.url("math-lib"), "--as", "math"], project) }
    end
  end
end

describe Zane::Commands::Fetch do
  it "refuses a tag that no longer points to the locked commit" do
    with_registry do |registry, project|
      registry.publish("math", "v1.0")
      zane(["add", registry.url("math")], project)[0].should eq 0
      FileUtils.rm_rf(Zane::Home.packages)
      repo = registry.dir / "math"
      File.write(repo / "src" / "math.zn", "package math; // moved\n")
      git(repo, "commit", "-q", "-am", "moved")
      git(repo, "tag", "-f", "v1.0")
      expect_raises(Zane::UserError, "security error") { zane(["fetch"], project) }
      Dir.exists?(entry("math", "v1.0") / "src").should be_false
    end
  end

  it "rewrites again for another compiler pin, from the archive it kept" do
    with_registry do |registry, project, log|
      registry.publish("math", "v1.0")
      zane(["add", registry.url("math")], project)[0].should eq 0
      lock = project / "zane-lock.coda"
      File.write(lock, File.read(lock).sub("0123456789abcdef0123456789abcdef01234567", "fedcba9876543210fedcba9876543210fedcba98"))
      zane(["fetch"], project).should eq({0, "Fetched 1 package for #{Zane::Target::HOST}.\n", ""})
      registry.fetched.size.should eq 1
      File.read_lines(log).count(&.starts_with?("--rewrite")).should eq 2
    end
  end
end
