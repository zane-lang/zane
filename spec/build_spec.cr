require "./spec_helper"

# The fake compiler, built once for every example.
FAKE_ZANEC = begin
  path = File.join(Dir.tempdir, "zane-spec-zanec-#{Process.pid}#{{{ flag?(:win32) ? ".exe" : "" }}}")
  status = Process.run("crystal", ["build", "spec/support/fake_zanec.cr", "-o", path], error: Process::Redirect::Inherit)
  raise "cannot build the fake compiler" unless status.success?
  path
end

private def with_project(kind = "application", deps = "", &)
  root = Path[File.join(Dir.tempdir, "zane-spec-#{Random::Secure.hex(6)}")]
  Dir.mkdir_p(root / "src")
  File.write(root / "zane.coda", <<-CODA)
    name demo
    kind #{kind}
    zane-version v0.1
    version-pattern v*.+.++

    deps [
        key version from
    #{deps}]
    CODA
  File.write(root / "src" / "main.zn", "package demo;\n")
  log = root / "zanec.log"
  ENV["ZANE_COMPILER"] = FAKE_ZANEC
  ENV["FAKE_ZANEC_LOG"] = log.to_s
  begin
    yield root, log
  ensure
    %w(ZANE_COMPILER FAKE_ZANEC_LOG FAKE_ZANEC_STATUS FAKE_PROGRAM_STATUS).each { |v| ENV.delete(v) }
    FileUtils.rm_rf(root)
  end
end

# Runs *command* from *dir*, returning its status, output and errors.
private def zane(command, args : Array(String), dir : Path)
  output, error = IO::Memory.new, IO::Memory.new
  status = command.new(args, output, error, dir, Zane::Home.toolchains).run
  {status, output.to_s, error.to_s}
end

private def logged(log : Path) : Array(String)
  File.exists?(log) ? File.read_lines(log) : [] of String
end

describe Zane::Workspace do
  it "finds the project from a directory inside it" do
    with_project do |root|
      ws = Zane::Workspace.find(root / "src")
      ws.root.should eq root
      ws.name.should eq "demo"
      ws.kind.application?.should be_true
      ws.zane_version.should eq "v0.1"
    end
  end

  it "says where to start when there is no project" do
    expect_raises(Zane::UserError, "no zane.coda in this directory or any above it") do
      Zane::Workspace.find(Path[Dir.tempdir] / "zane-spec-nowhere-#{Random::Secure.hex(4)}")
    end
  end

  it "refuses dependencies, which are not supported yet" do
    with_project(deps: "    core v1.0 release\n") do |root|
      expect_raises(Zane::UserError, "dependencies are not supported yet") { Zane::Workspace.find(root) }
    end
  end

  it "refuses a source file in a subdirectory of src/" do
    with_project do |root|
      Dir.mkdir_p(root / "src" / "nested" / "deeper")
      File.write(root / "src" / "nested" / "deeper" / "more.zn", "package demo;\n")
      expect_raises(Zane::UserError, "is in a subdirectory of src/") do
        Zane::Workspace.find(root).check_sources
      end
    end
  end
end

describe Zane::Compiler do
  it "takes ZANE_COMPILER first" do
    with_project do
      Zane::Compiler.locate("v0.1").path.should eq FAKE_ZANEC
    end
  end

  it "takes the toolchain installed for the project's version, then PATH" do
    home = Path[File.join(Dir.tempdir, "zane-spec-toolchains-#{Random::Secure.hex(4)}")]
    path = ENV["PATH"]?
    begin
      ENV["PATH"] = home.to_s
      expect_raises(Zane::UserError, "the compiler v0.1, which is not installed, and no zanec is on PATH") do
        Zane::Compiler.locate("v0.1", home)
      end
      Dir.mkdir_p(home / "v0.1" / "bin")
      File.copy(FAKE_ZANEC, home / "v0.1" / "bin" / Zane::Compiler::EXECUTABLE)
      File.write(home / "v0.1" / Zane::CompilerRelease::RECORD, "url u\ncommit c\n")
      Zane::Compiler.locate("v0.1", home).path.should eq (home / "v0.1" / "bin" / Zane::Compiler::EXECUTABLE).to_s
    ensure
      path ? (ENV["PATH"] = path) : ENV.delete("PATH")
      FileUtils.rm_rf(home)
    end
  end
end

describe Zane::Commands do
  it "checks the project as one package named by its manifest" do
    with_project do |root, log|
      zane(Zane::Commands::Check, [] of String, root / "src").should eq({0, "", ""})
      logged(log).should eq ["--check --kind application --package demo=#{root / "src"}"]
    end
  end

  it "passes on the compiler's failure" do
    with_project do |root|
      ENV["FAKE_ZANEC_STATUS"] = "1"
      status, _, error = zane(Zane::Commands::Check, [] of String, root)
      status.should eq 1
      error.should eq "fake compiler error\n"
    end
  end

  it "builds into out/host by default, and for a target into out/<target>" do
    with_project do |root, log|
      host = root / "out" / "host" / {{ flag?(:win32) ? "demo.exe" : "demo" }}
      zane(Zane::Commands::Build, [] of String, root)[0].should eq 0
      File.exists?(host).should be_true
      zane(Zane::Commands::Build, ["--target", "aarch64-unknown-linux-gnu"], root)[0].should eq 0
      zane(Zane::Commands::Build, ["--target", "x86_64-pc-windows-msvc"], root)[0].should eq 0
      logged(log).should eq [
        "--build #{host} --kind application --package demo=#{root / "src"}",
        "--build #{root / "out" / "aarch64-unknown-linux-gnu" / "demo"} --target aarch64-unknown-linux-gnu --kind application --package demo=#{root / "src"}",
        "--build #{root / "out" / "x86_64-pc-windows-msvc" / "demo.exe"} --target x86_64-pc-windows-msvc --kind application --package demo=#{root / "src"}",
      ]
    end
  end

  it "builds where -o says" do
    with_project do |root, log|
      target = root / "elsewhere" / "prog"
      zane(Zane::Commands::Build, ["-o", target.to_s], root)[0].should eq 0
      logged(log).first.should start_with "--build #{target} "
    end
  end

  it "refuses to build a library" do
    with_project(kind: "library") do |root, log|
      expect_raises(Zane::UserError, "`demo` is a library, which is not built into a program") do
        zane(Zane::Commands::Build, [] of String, root)
      end
      logged(log).should be_empty
    end
  end

  it "runs the program with the arguments after --, and exits with its status" do
    with_project do |root|
      ENV["FAKE_PROGRAM_STATUS"] = "3"
      zane(Zane::Commands::Run, ["--", "a", "--b"], root).should eq({3, "program ran with [a, --b]\n", ""})
    end
  end

  it "does not run a program that failed to build" do
    with_project do |root|
      ENV["FAKE_ZANEC_STATUS"] = "1"
      zane(Zane::Commands::Run, [] of String, root)[0].should eq 1
      File.exists?(root / "out" / "host").should be_true
      Dir.children(root / "out" / "host").should be_empty
    end
  end

  it "rejects a stray argument" do
    with_project do |root|
      expect_raises(Zane::UserError, "unexpected argument extra") do
        zane(Zane::Commands::Run, ["extra"], root)
      end
    end
  end

  it "cleans out/" do
    with_project do |root|
      zane(Zane::Commands::Build, [] of String, root)
      zane(Zane::Commands::Clean, [] of String, root)[0].should eq 0
      Dir.exists?(root / "out").should be_false
      zane(Zane::Commands::Clean, [] of String, root)[0].should eq 0
    end
  end
end
