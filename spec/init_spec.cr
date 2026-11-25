require "./spec_helper"

# A compiler repository with releases v0.0 through v0.3 (v0.1 annotated), and
# tags that are not releases. Built once; `ls-remote` reads it like the real one.
COMPILER = File.join(Dir.tempdir, "zane-spec-compiler-#{Process.pid}")

private def git(*args, dir = COMPILER) : String
  buf = IO::Memory.new
  status = Process.run("git", ["-C", dir, "-c", "user.name=spec", "-c", "user.email=spec@example.com"] + args.to_a, output: buf)
  raise "git #{args.join(' ')} failed" unless status.success?
  buf.to_s.strip
end

Dir.mkdir_p(COMPILER)
git("init", "-q")
git("commit", "-q", "--allow-empty", "-m", "first")
git("tag", "v0.0")
git("commit", "-q", "--allow-empty", "-m", "second")
git("tag", "-a", "v0.1", "-m", "release")
git("tag", "v0.1.5")
git("tag", "nightly")
V01 = git("rev-parse", "HEAD")
V00 = git("rev-parse", "HEAD~1")
git("tag", "v0.2")
git("commit", "-q", "--allow-empty", "-m", "machine operations")
git("tag", "v0.3")
V03 = git("rev-parse", "HEAD")

# A std repository with releases v0.9 and v0.10, which `init` pins the newest
# of. git reaches each repository in STD_ROOT at `https://example.com/<name>`
# through `insteadOf`, since a package URL cannot be a Windows path.
STD_ROOT = File.join(Dir.tempdir, "zane-spec-std-#{Process.pid}")
STD_DIR  = File.join(STD_ROOT, "std")
STD      = "https://example.com/std"
Dir.mkdir_p(File.join(STD_DIR, "lib", "core"))
File.write(File.join(STD_DIR, "zane.coda"), "zane-version v0.0\nversion-pattern v*.+\n\ndeps [\n    key version from\n]\n")
File.write(File.join(STD_DIR, "zane-lock.coda"), "zane-commit #{"0" * 40}\n\nresolutions [\n    key url commit\n]\n")
File.write(File.join(STD_DIR, "lib", "core", "core.zn"), "package core;\n")
git("init", "-q", dir: STD_DIR)
git("add", "-A", dir: STD_DIR)
git("commit", "-q", "-m", "first", dir: STD_DIR)
git("tag", "v0.9", dir: STD_DIR)
git("commit", "-q", "--allow-empty", "-m", "second", dir: STD_DIR)
git("tag", "v0.10", dir: STD_DIR)
git("tag", "nightly", dir: STD_DIR)
STD_V010 = git("rev-parse", "HEAD", dir: STD_DIR)

# The package cache of the specs that pass none of their own, never the real one.
PACKAGES = File.join(Dir.tempdir, "zane-spec-packages-#{Process.pid}")

STD_ENV = %w(GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0)

# Runs the block with git reaching STD_ROOT at `https://example.com/`.
private def with_std_registry(&)
  saved = STD_ENV.to_h { |k| {k, ENV[k]?} }
  ENV["GIT_CONFIG_COUNT"] = "1"
  ENV["GIT_CONFIG_KEY_0"] = "url.#{Path[STD_ROOT].to_posix}/.insteadOf"
  ENV["GIT_CONFIG_VALUE_0"] = "https://example.com/"
  begin
    yield
  ensure
    saved.each { |k, v| v ? (ENV[k] = v) : ENV.delete(k) }
  end
end

private def with_tmp(&)
  dir = File.join(Dir.tempdir, "zane-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  begin
    yield Path[dir]
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def init(args : Array(String), input = "", interactive = false, url = COMPILER, std = STD, packages = Path[PACKAGES]) : String
  output = IO::Memory.new
  Zane::Commands::Init.new(args, IO::Memory.new(input), output, interactive, url, std_url: std, packages: packages).run
  output.to_s
end

# A copy of the std repository named *name*, reached at its own URL, to
# delete when a spec takes std offline.
private def copy_std(name : String) : String
  FileUtils.cp_r(STD_DIR, File.join(STD_ROOT, name))
  "https://example.com/#{name}"
end

# Installs a toolchain as `zane toolchain install` leaves it, under ZANE_HOME.
private def install(tag : String, commit : String, url = COMPILER, record = true) : Nil
  dir = Zane::Home.toolchains / tag
  Dir.mkdir_p(dir)
  File.write(dir / Zane::CompilerRelease::RECORD, "url #{url}\ncommit #{commit}\n") if record
end

private def with_toolchains(&)
  yield
ensure
  FileUtils.rm_rf(Zane::Home.dir)
end

describe Zane::CompilerRelease do
  it "reads the major and minor of a canonical vMAJOR.MINOR tag alone" do
    Zane::CompilerRelease.version("v0.14").should eq({0, 14})
    Zane::CompilerRelease.version("v10.0").should eq({10, 0})
    ["v01.0", "v1.00", "v1", "v1.0.0", "1.0"].each { |tag| Zane::CompilerRelease.version(tag).should be_nil }
  end

  it "takes the newest vMAJOR.MINOR tag, at the commit an annotated tag points to" do
    release = Zane::CompilerRelease.resolve(nil, COMPILER)
    release.should eq Zane::CompilerRelease.new("v0.3", V03)
    Zane::CompilerRelease.resolve("v0.1", COMPILER).should eq Zane::CompilerRelease.new("v0.1", V01)
  end

  it "takes a named release" do
    Zane::CompilerRelease.resolve("v0.0", COMPILER).should eq Zane::CompilerRelease.new("v0.0", V00)
  end

  it "orders minor versions as numbers" do
    tags = Zane::CompilerRelease.parse("a\trefs/tags/v0.9\nb\trefs/tags/v0.10\nc\trefs/tags/v0.10^{}\n")
    tags.should eq({"v0.9" => "a", "v0.10" => "c"})
  end

  it "lists the toolchains installed from a repository" do
    with_toolchains do
      install("v0.0", V00)
      install("v0.9", "a")
      install("v0.10", "b")
      install("v0.11", "c", record: false)
      install("v0.12", "d", url: "https://example.com/fork")
      install("nightly", "e")
      Zane::CompilerRelease.installed(Zane::Home.toolchains, COMPILER).should eq({"v0.0" => V00, "v0.9" => "a", "v0.10" => "b"})
      Zane::CompilerRelease.resolve(nil, COMPILER, Zane::Home.toolchains).should eq Zane::CompilerRelease.new("v0.10", "b", true)
    end
  end

  it "looks a release up online when it is not installed" do
    with_toolchains do
      install("v0.0", V00)
      Zane::CompilerRelease.resolve("v0.1", COMPILER, Zane::Home.toolchains).should eq Zane::CompilerRelease.new("v0.1", V01)
      Zane::CompilerRelease.resolve("v0.0", COMPILER, Zane::Home.toolchains).should eq Zane::CompilerRelease.new("v0.0", V00, true)
    end
  end

  it "refuses a toolchain record it cannot read" do
    with_toolchains do
      install("v0.0", V00, record: false)
      File.write(Zane::Home.toolchains / "v0.0" / "toolchain.coda", "url #{COMPILER}\n")
      expect_raises(Zane::UserError, "toolchain.coda is not a toolchain record") do
        Zane::CompilerRelease.installed(Zane::Home.toolchains, COMPILER)
      end
    end
  end

  it "refuses a tag that is not a release" do
    expect_raises(Zane::UserError, "has no release v0.1.5; its releases are v0.0, v0.1, v0.2, v0.3") do
      Zane::CompilerRelease.resolve("v0.1.5", COMPILER)
    end
  end
end

describe Zane::Project do
  it "makes a camelCase name from a directory name" do
    Zane::Project.name_from("my-tool").should eq "myTool"
    Zane::Project.name_from("MyLib").should eq "myLib"
    Zane::Project.name_from("geometry_2d").should eq "geometry2d"
    Zane::Project.name_from("2fast").should be_nil
    Zane::Project.name_from("---").should be_nil
  end

  it "checks version patterns" do
    Zane::Project.version_pattern_error("v*.+.++").should be_nil
    Zane::Project.version_pattern_error("v*.+.-").should eq "`+` and `-` share a priority level"
    Zane::Project.version_pattern_error("v*..+").should eq "it is empty"
  end
end

describe Zane::Commands::Init do
  around_each do |example|
    with_std_registry { example.run }
  end

  it "creates an application with the newest compiler and std pinned" do
    with_tmp do |tmp|
      output = init([(tmp / "my-app").to_s, "--no-git"])
      output.should contain "built by the compiler v0.3, the newest release."
      output.should contain "It depends on std v0.10, compiled from source"
      root = tmp / "my-app"

      manifest = read_coda(root / "zane.coda")
      manifest.keys.should eq ["zane-version", "version-pattern", "deps"]
      manifest["zane-version"].should eq "v0.3"
      manifest["version-pattern"].should eq "v*.+.++"
      manifest["deps"].should eq({"columns" => ["version", "from"], "rows" => {"std" => {"version" => "v0.10", "from" => "source"}}})

      lock = read_coda(root / "zane-lock.coda")
      lock.keys.should eq ["zane-commit", "resolutions"]
      lock["zane-commit"].should eq V03
      lock["resolutions"].should eq({"columns" => ["url", "commit"], "rows" => {"std" => {"url" => STD, "commit" => STD_V010}}})

      source = File.read(root / "bin" / "myApp" / "main.zn")
      source.should start_with "package myApp;\n\nimport core$;\n"
      source.should contain "console Console(@program$console);"
      source.should contain %(console!print("hello world");)
      source.should_not contain "@primitives$"
      Dir.exists?(root / "test").should be_false
      File.read(root / ".gitignore").should eq "out/\ncompile_commands.json\n"
      File.exists?(root / ".git").should be_false
    end
  end

  it "depends on nothing and uses only the intrinsics with --no-std" do
    with_tmp do |tmp|
      output = init([(tmp / "app").to_s, "--no-std", "--no-git"], std: "https://zane.invalid/std")
      output.should_not contain "std"
      root = tmp / "app"
      read_coda(root / "zane.coda")["deps"].should eq({"columns" => ["version", "from"], "rows" => {} of String => Hash(String, String)})
      read_coda(root / "zane-lock.coda")["resolutions"].should eq({"columns" => ["url", "commit"], "rows" => {} of String => Hash(String, String)})
      source = File.read(root / "bin" / "app" / "main.zn")
      source.should_not contain "import core$;"
      source.should contain "@primitives$Unit main() {"
    end
  end

  it "checks out the std it pins into the package cache" do
    with_tmp do |tmp|
      packages = tmp / "packages"
      init([(tmp / "app").to_s, "--no-git"], packages: packages)
      src = packages.join(Zane::PackageUrl.parse(STD).normalized.split('/')) / "v0.10" / "src"
      Zane::Git.head(src).should eq STD_V010
    end
  end

  it "pins the newest std in the package cache when std cannot be reached" do
    with_tmp do |tmp|
      packages = tmp / "packages"
      std = copy_std("offline-#{Random::Secure.hex(4)}")
      Zane::Std.fetch(std, packages).should eq Zane::Std::Pin.new("v0.10", STD_V010, false)
      FileUtils.rm_rf(File.join(STD_ROOT, Path[std].basename))

      output = init([(tmp / "app").to_s, "--no-git"], std: std, packages: packages)
      output.should contain "It depends on std v0.10, the newest in the package cache, since std could not be reached"
      read_coda(tmp / "app" / "zane.coda")["deps"].should eq({"columns" => ["version", "from"], "rows" => {"std" => {"version" => "v0.10", "from" => "source"}}})
      read_coda(tmp / "app" / "zane-lock.coda")["resolutions"].should eq({"columns" => ["url", "commit"], "rows" => {"std" => {"url" => std, "commit" => STD_V010}}})
      File.read(tmp / "app" / "bin" / "app" / "main.zn").should contain "import core$;"
    end
  end

  it "takes the highest version in the package cache, as numbers" do
    with_tmp do |tmp|
      packages = tmp / "packages"
      dir = packages.join(Zane::PackageUrl.parse(STD).normalized.split('/'))
      {"v0.9", "v0.10"}.each do |tag|
        git("clone", "-q", "--branch", tag, STD_DIR, (dir / tag / "src").to_s, dir: tmp.to_s)
      end
      Dir.mkdir_p(dir / "v0.11")
      Dir.mkdir_p(dir / "v0.12" / "src")
      Zane::Std.cached(STD, packages).should eq Zane::Std::Pin.new("v0.10", STD_V010, true)
      Zane::Std.cached("https://zane.invalid/std", packages).should be_nil
    end
  end

  it "refuses a package name std has, and writes nothing" do
    with_tmp do |tmp|
      expect_raises(Zane::UserError, "std v0.10 has a package named `core`") do
        init([(tmp / "core").to_s, "--no-git"], packages: tmp / "packages")
      end
      File.exists?(tmp / "core").should be_false
    end
  end

  it "refuses a std without a core package, and writes nothing" do
    with_tmp do |tmp|
      std = copy_std("coreless-#{Random::Secure.hex(4)}")
      dir = File.join(STD_ROOT, Path[std].basename)
      git("mv", "lib/core", "lib/other", dir: dir)
      git("mv", "lib/other/core.zn", "lib/other/other.zn", dir: dir)
      git("commit", "-q", "-m", "no core", dir: dir)
      git("tag", "v0.11", dir: dir)
      expect_raises(Zane::UserError, "std v0.11 has no public `core` package") do
        init([(tmp / "app").to_s, "--no-git"], std: std, packages: tmp / "packages")
      end
      File.exists?(tmp / "app").should be_false
    end
  end

  it "refuses a std that needs a newer compiler than the one pinned, and writes nothing" do
    with_tmp do |tmp|
      std = copy_std("newer-#{Random::Secure.hex(4)}")
      dir = File.join(STD_ROOT, Path[std].basename)
      File.write(File.join(dir, "zane.coda"), File.read(File.join(dir, "zane.coda")).sub("v0.0", "v0.9"))
      git("commit", "-q", "-am", "needs v0.9", dir: dir)
      git("tag", "v0.11", dir: dir)
      expect_raises(Zane::UserError, "std v0.11 needs compiler v0.9 or later, and this project is pinned to v0.3") do
        init([(tmp / "app").to_s, "--no-git"], std: std, packages: tmp / "packages")
      end
      File.exists?(tmp / "app").should be_false
    end
  end

  it "orders version tags as numbers, leaving out a number too large to compare" do
    Zane::Git.versions(["v0.9", "nightly", "v1.99999999999999999999", "v0.10"]).should eq ["v0.10", "v0.9"]
  end

  it "writes nothing when std cannot be reached and is not in the package cache" do
    with_tmp do |tmp|
      expect_raises(Zane::UserError, "Run `zane self install-std` once online, or run again with --no-std") do
        init([(tmp / "app").to_s, "--no-git"], std: "https://example.com/missing", packages: tmp / "packages")
      end
      File.exists?(tmp / "app").should be_false
    end
  end

  it "pins the newest installed compiler without going online" do
    with_tmp do |tmp|
      with_toolchains do
        offline = "https://zane.invalid/compiler"
        install("v0.0", V00, url: offline)
        output = init([(tmp / "app").to_s, "--no-std", "--no-git"], url: offline, std: "https://zane.invalid/std")
        output.should contain "built by the compiler v0.0, the newest one installed."
        read_coda(tmp / "app" / "zane-lock.coda")["zane-commit"].should eq V00
      end
    end
  end

  it "takes the directory after --" do
    with_tmp do |tmp|
      init(["--no-git", "--", (tmp / "after").to_s])
      File.exists?(tmp / "after" / "zane.coda").should be_true
    end
  end

  it "writes nothing when git is to be used and is not installed" do
    with_tmp do |tmp|
      with_toolchains do
        install("v0.0", V00)
        path = ENV["PATH"]?
        ENV["PATH"] = tmp.to_s
        begin
          expect_raises(Zane::UserError, "git is not installed; run again with --no-git") do
            init([(tmp / "app").to_s])
          end
        ensure
          path ? (ENV["PATH"] = path) : ENV.delete("PATH")
        end
        File.exists?(tmp / "app").should be_false
      end
    end
  end

  it "creates a library package with a test package that imports it" do
    with_tmp do |tmp|
      output = init([(tmp / "geo").to_s, "--lib", "--name", "geometry", "--zane-version", "v0.3", "--no-git"])
      output.should contain "with the library package lib/geometry/ and its test package test/geometry/"
      manifest = read_coda(tmp / "geo" / "zane.coda")
      manifest["zane-version"].should eq "v0.3"
      library = File.read(tmp / "geo" / "lib" / "geometry" / "geometry.zn")
      library.should start_with "package geometry;\n\nimport core$;\n"
      library.should contain "Int double(n Int) => n + n;"
      Dir.exists?(tmp / "geo" / "bin").should be_false
      test = File.read(tmp / "geo" / "test" / "geometry" / "main.zn")
      test.should start_with "package test;\n\nimport core$;\nimport geometry;\n"
      test.should contain "if(geometry$double(Int(21)) ~= 42) {"
      test.should contain %(abort @primitives$String("double(21) is not 42");)
    end
  end

  it "writes a library and its test with only the intrinsics with --no-std" do
    with_tmp do |tmp|
      init([(tmp / "geo").to_s, "--lib", "--name", "geometry", "--no-std", "--no-git"])
      library = File.read(tmp / "geo" / "lib" / "geometry" / "geometry.zn")
      library.should contain "@primitives$I64 double(n @primitives$I64) => @operators$add(n, n);"
      test = File.read(tmp / "geo" / "test" / "geometry" / "main.zn")
      test.should start_with "package test;\n\nimport geometry;\n"
      test.should contain "check(@operators$equal(geometry$double(I64(21)), I64(42)));"
      test.should contain "@controlflow$branch(@operators$not(ok), {"
      test.should contain %(passed String.escaped("ok\\n");)
    end
  end

  it "accepts newer minor and major compiler versions for a library without going online" do
    with_tmp do |tmp|
      with_toolchains do
        offline = "https://zane.invalid/compiler"
        {"v0.3", "v0.10", "v1.0"}.each do |tag|
          install(tag, V03, url: offline)
          root = tmp / tag
          init([root.to_s, "--lib", "--name", "geometry", "--no-std", "--no-git"], url: offline, std: "https://zane.invalid/std")
          read_coda(root / "zane.coda")["zane-version"].should eq tag
          File.read(root / "lib" / "geometry" / "geometry.zn").should contain "@operators$add(n, n)"
        end
      end
    end
  end

  it "accepts the files of a new repository, and adds out/ and compile_commands.json to its .gitignore" do
    with_tmp do |tmp|
      File.write(tmp / "README.md", "# x\n")
      File.write(tmp / "LICENSE", "")
      File.write(tmp / ".gitignore", "*.o")
      init([tmp.to_s, "--name", "x", "--no-git"])
      File.read(tmp / ".gitignore").should eq "*.o\nout/\ncompile_commands.json\n"
    end
  end

  it "refuses a directory that holds anything else, and writes nothing" do
    with_tmp do |tmp|
      Dir.mkdir(tmp / "other-project")
      File.write(tmp / "notes.txt", "")
      expect_raises(Zane::UserError, "holds notes.txt, other-project") do
        init([tmp.to_s, "--name", "x"])
      end
      Dir.children(tmp).sort.should eq ["notes.txt", "other-project"]
    end
  end

  it "needs --name when the directory's name is not a package name" do
    with_tmp do |tmp|
      expect_raises(Zane::UserError, "cannot make a package name from `2d`") do
        init([(tmp / "2d").to_s])
      end
      File.exists?(tmp / "2d").should be_false
    end
  end

  it "initialises a Git repository unless it is inside one" do
    with_tmp do |tmp|
      init([(tmp / "a").to_s])
      File.directory?(tmp / "a" / ".git").should be_true
      init([(tmp / "a" / "nested").to_s])
      File.exists?(tmp / "a" / "nested" / ".git").should be_false
    end
  end

  it "asks each question, re-asking an invalid answer" do
    with_tmp do |tmp|
      answers = "y\nBad Name\ntools\nlib\nv*.+.+\nv*.+\nn\n"
      output = init([(tmp / "my-tools").to_s], answers, interactive: true)
      output.should contain "Package name [myTools]: "
      output.should contain "`Bad Name` is not a package name"
      output.should contain "`v*.+.+` is not a version pattern: `+` and `+` share a priority level"
      manifest = read_coda(tmp / "my-tools" / "zane.coda")
      manifest["version-pattern"].should eq "v*.+"
      File.exists?(tmp / "my-tools" / "lib" / "tools" / "tools.zn").should be_true
      File.exists?(tmp / "my-tools" / ".git").should be_false
    end
  end

  it "writes nothing when the first question is declined" do
    with_tmp do |tmp|
      expect_raises(Zane::UserError, "cancelled") do
        init([(tmp / "x").to_s], "n\n", interactive: true)
      end
      File.exists?(tmp / "x").should be_false
    end
  end

  it "asks nothing for a flag it was given" do
    with_tmp do |tmp|
      output = init([(tmp / "x").to_s, "--name", "x", "--app", "--version-pattern", "v*.+", "--no-git"], "\n", interactive: true)
      output.should_not contain "Package name"
      output.should_not contain "Library or application"
      output.should_not contain "Version pattern"
    end
  end
end

describe Zane::Commands::SelfCommand do
  around_each do |example|
    with_std_registry { example.run }
  end

  it "puts the newest std in the package cache with install-std" do
    with_tmp do |tmp|
      output = IO::Memory.new
      packages = tmp / "packages"
      Zane::Commands::SelfCommand.new(["install-std"], output, IO::Memory.new, STD, packages).run.should eq 0
      output.to_s.should contain "std v0.10 is in the package cache"
      Zane::Std.cached(STD, packages).should eq Zane::Std::Pin.new("v0.10", STD_V010, true)
    end
  end

  it "refuses arguments after install-std" do
    expect_raises(Zane::UserError, "usage: zane self update") do
      Zane::Commands::SelfCommand.new(["install-std", "v0.1"], IO::Memory.new, IO::Memory.new).run
    end
  end
end

Spec.after_suite do
  FileUtils.rm_rf(COMPILER)
  FileUtils.rm_rf(STD_ROOT)
  FileUtils.rm_rf(PACKAGES)
end
