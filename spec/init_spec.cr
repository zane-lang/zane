require "./spec_helper"

# A compiler repository with releases v0.0 and v0.1 (annotated), and tags that
# are not releases. Built once; `ls-remote` reads it like the real one.
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

private def with_tmp(&)
  dir = File.join(Dir.tempdir, "zane-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  begin
    yield Path[dir]
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def init(args : Array(String), input = "", interactive = false, url = COMPILER) : String
  output = IO::Memory.new
  Zane::Commands::Init.new(args, IO::Memory.new(input), output, interactive, url).run
  output.to_s
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
  it "takes the newest vMAJOR.MINOR tag, at the commit an annotated tag points to" do
    release = Zane::CompilerRelease.resolve(nil, COMPILER)
    release.should eq Zane::CompilerRelease.new("v0.1", V01)
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
    expect_raises(Zane::UserError, "has no release v0.1.5; its releases are v0.0, v0.1") do
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
  it "creates an application with the newest compiler pinned" do
    with_tmp do |tmp|
      output = init([(tmp / "my-app").to_s, "--no-git"])
      output.should contain "built by the compiler v0.1, the newest release."
      root = tmp / "my-app"

      manifest = read_coda(root / "zane.coda")
      manifest.keys.should eq ["name", "kind", "zane-version", "version-pattern", "deps"]
      manifest["name"].should eq "myApp"
      manifest["kind"].should eq "application"
      manifest["zane-version"].should eq "v0.1"
      manifest["version-pattern"].should eq "v*.+.++"
      manifest["deps"].should eq({"columns" => ["version", "from"], "rows" => {} of String => Hash(String, String)})

      lock = read_coda(root / "zane-lock.coda")
      lock["resolutions"].should eq({"columns" => ["url", "commit"], "rows" => {"zane" => {"url" => COMPILER, "commit" => V01}}})

      File.read(root / "src" / "main.zn").should start_with "package myApp;\n"
      File.read(root / ".gitignore").should eq "out/\n"
      File.exists?(root / ".git").should be_false
    end
  end

  it "pins the newest installed compiler without going online" do
    with_tmp do |tmp|
      with_toolchains do
        offline = "https://zane.invalid/compiler"
        install("v0.0", V00, url: offline)
        output = init([(tmp / "app").to_s, "--no-git"], url: offline)
        output.should contain "built by the compiler v0.0, the newest one installed."
        read_coda(tmp / "app" / "zane-lock.coda")["resolutions"].should eq(
          {"columns" => ["url", "commit"], "rows" => {"zane" => {"url" => offline, "commit" => V00}}})
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

  it "creates a library whose source file is named after it, with a test package that imports it" do
    with_tmp do |tmp|
      init([(tmp / "geo").to_s, "--lib", "--name", "geometry", "--zane-version", "v0.0", "--no-git"])
      manifest = read_coda(tmp / "geo" / "zane.coda")
      manifest["kind"].should eq "library"
      manifest["zane-version"].should eq "v0.0"
      File.read(tmp / "geo" / "src" / "geometry.zn").should contain "package geometry;"
      File.exists?(tmp / "geo" / "src" / "main.zn").should be_false
      test = File.read(tmp / "geo" / "test" / "main.zn")
      test.should start_with "package test;\n\nimport geometry;\n"
      test.should contain "check(geometry$double(Int(21)) == Int(42));"
      test.should contain %(passed String("ok\\n");)
    end
  end

  it "writes no test package for an application" do
    with_tmp do |tmp|
      init([(tmp / "app").to_s, "--app", "--zane-version", "v0.0", "--no-git"])
      Dir.exists?(tmp / "app" / "test").should be_false
    end
  end

  it "accepts the files of a new repository, and adds out/ to its .gitignore" do
    with_tmp do |tmp|
      File.write(tmp / "README.md", "# x\n")
      File.write(tmp / "LICENSE", "")
      File.write(tmp / ".gitignore", "*.o")
      init([tmp.to_s, "--name", "x", "--no-git"])
      File.read(tmp / ".gitignore").should eq "*.o\nout/\n"
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
      output.should contain "Project name [myTools]: "
      output.should contain "`Bad Name` is not a package name"
      output.should contain "`v*.+.+` is not a version pattern: `+` and `+` share a priority level"
      manifest = read_coda(tmp / "my-tools" / "zane.coda")
      manifest["name"].should eq "tools"
      manifest["kind"].should eq "library"
      manifest["version-pattern"].should eq "v*.+"
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
      output.should_not contain "Project name"
      output.should_not contain "Library or application"
      output.should_not contain "Version pattern"
    end
  end
end

Spec.after_suite { FileUtils.rm_rf(COMPILER) }
