require "./spec_helper"

# The fake compiler, built once for every example.
FAKE_ZANEC = begin
  path = File.join(Dir.tempdir, "zane-spec-zanec-#{Process.pid}#{{{ flag?(:win32) ? ".exe" : "" }}}")
  status = Process.run("crystal", ["build", "spec/support/fake_zanec.cr", "-o", path], error: Process::Redirect::Inherit)
  raise "cannot build the fake compiler" unless status.success?
  path
end

# The variables a project example sets, restored after it.
PROJECT_ENV = %w(ZANE_COMPILER FAKE_ZANEC_LOG FAKE_ZANEC_STATUS FAKE_PROGRAM_STATUS)

EXE = {{ flag?(:win32) ? ".exe" : "" }}

# A project of one program, bin/demo/, unless *files* lays out others: each
# a path from the root and what the file holds.
private def with_project(files = {"bin/demo/main.zn" => "package demo;\n"}, deps = "", &)
  root = Path[File.join(Dir.tempdir, "zane-spec-#{Random::Secure.hex(6)}")]
  Dir.mkdir_p(root)
  File.write(root / "zane.coda", <<-CODA)
    zane-version v0.1
    version-pattern v*.+.++

    deps [
        key version from
    #{deps}]
    CODA
  File.write(root / "zane-lock.coda", <<-CODA)
    resolutions [
        key url commit
        zane https://github.com/zane-lang/compiler 0123456789abcdef0123456789abcdef01234567
    ]
    CODA
  files.each do |path, text|
    Dir.mkdir_p((root / path).parent)
    File.write(root / path, text)
  end
  log = root / "zanec.log"
  saved = PROJECT_ENV.to_h { |v| {v, ENV[v]?} }
  ENV["ZANE_COMPILER"] = FAKE_ZANEC
  ENV["FAKE_ZANEC_LOG"] = log.to_s
  begin
    yield root, log
  ensure
    saved.each { |v, value| value ? (ENV[v] = value) : ENV.delete(v) }
    FileUtils.rm_rf(root)
  end
end

# A project with library packages, a subpackage, a program and two test
# packages, one nested.
LAYOUT = {
  "lib/math/math.zn"         => "package math;\n",
  "lib/gui/gui.zn"           => "package gui;\n",
  "lib/gui/opengl/opengl.zn" => "package opengl;\n",
  "lib/_shaders/shaders.zn"  => "package _shaders;\n",
  "bin/viewer/main.zn"       => "package viewer;\n",
  "test/math/main.zn"        => "package test;\n",
  "test/gui/opengl/main.zn"  => "package test;\n",
}

# The flags every build of LAYOUT gives its library packages.
private def library_flags(root : Path) : String
  "--package _shaders=#{root / "lib" / "_shaders"} --package gui=#{root / "lib" / "gui"} " \
  "--package gui.opengl=#{root / "lib" / "gui" / "opengl"} --package math=#{root / "lib" / "math"} " \
  "--import _shaders:gui=gui --import _shaders:math=math " \
  "--import gui:_shaders=_shaders --import gui:math=math --import gui:opengl=gui.opengl " \
  "--import gui.opengl:_shaders=_shaders --import gui.opengl:math=math " \
  "--import math:_shaders=_shaders --import math:gui=gui"
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
      ws = Zane::Workspace.find(root / "bin" / "demo")
      ws.root.should eq root
      ws.zane_version.should eq "v0.1"
    end
  end

  it "says where to start when there is no project" do
    expect_raises(Zane::UserError, "no zane.coda in this directory or any above it") do
      Zane::Workspace.find(Path[Dir.tempdir] / "zane-spec-nowhere-#{Random::Secure.hex(4)}")
    end
  end

  it "refuses a dependency the lock file has no row for" do
    with_project(deps: "    core v1.0 release\n") do |root|
      expect_raises(Zane::UserError, "zane-lock.coda has no row for `core`") { Zane::Workspace.find(root) }
    end
  end

  it "finds the lines that import any of some packages, in every package" do
    with_project(LAYOUT.merge({"bin/viewer/main.zn" => "package viewer;\nimport math$double;\nimport mathExtra;\n",
                               "test/math/main.zn"  => "package test;\n  import gui as g;\n"})) do |root|
      Zane::Workspace.find(root).importers(["math", "gui"]).should eq [{"bin/viewer/main.zn", 2}, {"test/math/main.zn", 2}]
    end
  end
end

describe Zane::Layout do
  it "reads the library packages, their subpackages, the programs and the test packages" do
    with_project(LAYOUT) do |root|
      layout = Zane::Layout.new(root)
      layout.libs.map(&.path).should eq ["_shaders", "gui", "gui.opengl", "math"]
      layout.public_libs.map(&.name).should eq ["gui", "math"]
      layout.programs.map(&.name).should eq ["viewer"]
      layout.tests.map(&.label).should eq ["gui/opengl", "math"]
      opengl = layout.lib?("gui.opengl").not_nil!
      {opengl.name, opengl.parent, opengl.top, opengl.top?}.should eq({"opengl", "gui", "gui", false})
    end
  end

  it "gives each package the keys of packages.md §4.3" do
    with_project(LAYOUT) do |root|
      layout = Zane::Layout.new(root)
      keys = ->(path : String) { layout.keys(layout.lib?(path).not_nil!).map { |k, l| "#{k}=#{l.path}" } }
      keys.call("gui").should eq ["_shaders=_shaders", "math=math", "opengl=gui.opengl"]
      keys.call("gui.opengl").should eq ["_shaders=_shaders", "math=math"]
      keys.call("math").should eq ["_shaders=_shaders", "gui=gui"]
      layout.program_keys.map(&.first).should eq ["_shaders", "gui", "math"]
      layout.test_keys(layout.tests.first).map { |k, l| "#{k}=#{l.path}" }.should eq [
        "_shaders=_shaders", "gui=gui", "math=math", "opengl=gui.opengl",
      ]
    end
  end

  it "holds the layout to the rules of packages.md §2 and §7" do
    {
      {"lib/stray.zn" => ""} => "is directly in lib/",
      {"bin/demo/main.zn" => "", "bin/demo/part/x.zn" => ""} => "is in a subdirectory of bin/demo/",
      {"lib/math/m.zn" => "", "test/math/opengl/main.zn" => ""} => "test/math/opengl/ tests no subpackage",
      {"lib/math/m.zn" => "", "bin/math/main.zn" => ""} => "bin/math/ has the name of the library package",
      {"lib/test/t.zn" => ""} => "lib/test/ cannot be a library package",
      {"lib/math/m.zn" => "", "lib/gui/g.zn" => "", "lib/gui/math/x.zn" => ""} => "a subpackage's name differs",
      {"lib/gui/g.zn" => "", "lib/gui/_x/x.zn" => ""} => "only a top-level library package's name may start with `_`",
      {"lib/gui/g.zn" => "", "lib/gui/widgets/button/b.zn" => ""} => "has no package above it",
      {"lib/My-Lib/m.zn" => ""} => "is not a package name",
      {"lib/math/README" => ""} => "holds no .zn files",
      {"README" => ""} => "has no packages",
    }.each do |files, message|
      with_project(files) do |root|
        expect_raises(Zane::UserError, message) { Zane::Layout.new(root) }
      end
    end
  end

  {% unless flag?(:win32) %}
    it "does not follow a symbolic link that loops back into lib/" do
      with_project({"lib/math/m.zn" => ""}) do |root|
        File.symlink(root / "lib", root / "lib" / "math" / "back")
        Zane::Layout.new(root).libs.map(&.path).should eq ["math"]
      end
    end
  {% end %}
end

describe Zane::Compiler do
  it "takes ZANE_COMPILER first" do
    with_project do
      Zane::Compiler.locate("v0.1").path.should eq FAKE_ZANEC
    end
  end

  it "takes the toolchain installed for the project's version, then PATH" do
    home = Path[File.join(Dir.tempdir, "zane-spec-toolchains-#{Random::Secure.hex(4)}")]
    path, compiler = ENV["PATH"]?, ENV["ZANE_COMPILER"]?
    begin
      ENV.delete("ZANE_COMPILER")
      ENV["PATH"] = home.to_s
      expect_raises(Zane::UserError, "the compiler v0.1, which is not installed, and no zanec is on PATH") do
        Zane::Compiler.locate("v0.1", home)
      end
      Dir.mkdir_p(home / "v0.1" / "bin")
      File.copy(FAKE_ZANEC, home / "v0.1" / "bin" / Zane::Compiler::EXECUTABLE)
      File.write(home / "v0.1" / Zane::CompilerRelease::RECORD, "url https://example.com/other\ncommit c\n")
      expect_raises(Zane::UserError, "no zanec is on PATH") { Zane::Compiler.locate("v0.1", home) }
      File.write(home / "v0.1" / Zane::CompilerRelease::RECORD, "url #{Zane::CompilerRelease::URL}\ncommit c\n")
      Zane::Compiler.locate("v0.1", home).path.should eq (home / "v0.1" / "bin" / Zane::Compiler::EXECUTABLE).to_s
    ensure
      path ? (ENV["PATH"] = path) : ENV.delete("PATH")
      compiler ? (ENV["ZANE_COMPILER"] = compiler) : ENV.delete("ZANE_COMPILER")
      FileUtils.rm_rf(home)
    end
  end
end

describe Zane::Commands do
  it "reports a compiler that cannot be started" do
    with_project do |root|
      ENV["ZANE_COMPILER"] = (root / "zane.coda").to_s
      expect_raises(Zane::UserError, "cannot run #{root / "zane.coda"}") do
        zane(Zane::Commands::Check, [] of String, root)
      end
    end
  end

  it "checks the library packages, then each program, then each test package, each the root of its own build" do
    with_project(LAYOUT) do |root, log|
      zane(Zane::Commands::Check, [] of String, root / "lib").should eq({0, "", ""})
      libs = library_flags(root)
      logged(log).should eq [
        "--check --kind library #{libs}",
        "--check --kind application --package viewer=#{root / "bin" / "viewer"} #{libs} " \
        "--import viewer:_shaders=_shaders --import viewer:gui=gui --import viewer:math=math",
        "--check --kind application --package test=#{root / "test" / "gui" / "opengl"} #{libs} " \
        "--import test:_shaders=_shaders --import test:gui=gui --import test:math=math --import test:opengl=gui.opengl",
        "--check --kind application --package test=#{root / "test" / "math"} #{libs} " \
        "--import test:_shaders=_shaders --import test:gui=gui --import test:math=math",
      ]
    end
  end

  it "gives a build whose packages import nothing its first package's own name, so it is held to its keys" do
    with_project do |root, log|
      zane(Zane::Commands::Check, [] of String, root).should eq({0, "", ""})
      logged(log).should eq ["--check --kind application --package demo=#{root / "bin" / "demo"} --import demo:demo=demo"]
    end
  end

  it "passes on the compiler's failure, and checks nothing after it" do
    with_project(LAYOUT) do |root, log|
      ENV["FAKE_ZANEC_STATUS"] = "1"
      status, _, error = zane(Zane::Commands::Check, [] of String, root)
      status.should eq 1
      error.should eq "fake compiler error\n"
      logged(log).size.should eq 1
    end
  end

  it "builds into out/host by default, and for a target into out/<target>" do
    with_project do |root, log|
      host = root / "out" / "host" / "demo#{EXE}"
      zane(Zane::Commands::Build, [] of String, root)[0].should eq 0
      File.exists?(host).should be_true
      zane(Zane::Commands::Build, ["--target", "aarch64-unknown-linux-gnu"], root)[0].should eq 0
      zane(Zane::Commands::Build, ["--target", "x86_64-pc-windows-msvc"], root)[0].should eq 0
      flags = "--kind application --package demo=#{root / "bin" / "demo"} --import demo:demo=demo"
      logged(log).should eq [
        "--build #{host} --optimize #{flags}",
        "--build #{root / "out" / "aarch64-unknown-linux-gnu" / "demo"} --target aarch64-unknown-linux-gnu --optimize #{flags}",
        "--build #{root / "out" / "x86_64-pc-windows-msvc" / "demo.exe"} --target x86_64-pc-windows-msvc --optimize #{flags}",
      ]
    end
  end

  it "builds every program, or the one named, and -o only for one" do
    files = {"bin/demo/main.zn" => "package demo;\n", "bin/tool/main.zn" => "package tool;\n"}
    with_project(files) do |root, log|
      status, output, _ = zane(Zane::Commands::Build, [] of String, root)
      status.should eq 0
      output.lines.size.should eq 2
      File.exists?(root / "out" / "host" / "tool#{EXE}").should be_true
      expect_raises(Zane::UserError, "-o names one file, and the project has 2 programs") do
        zane(Zane::Commands::Build, ["-o", (root / "x").to_s], root)
      end
      zane(Zane::Commands::Build, ["tool", "-o", (root / "elsewhere" / "prog").to_s], root)[0].should eq 0
      logged(log).last.should start_with "--build #{root / "elsewhere" / "prog"} --optimize --kind application --package tool="
      expect_raises(Zane::UserError, "bin/nope/ is no program; the programs are demo, tool") do
        zane(Zane::Commands::Build, ["nope"], root)
      end
    end
  end

  it "refuses to build a project with no program" do
    with_project({"lib/math/m.zn" => "package math;\n"}) do |root, log|
      expect_raises(Zane::UserError, "has no program to build") do
        zane(Zane::Commands::Build, [] of String, root)
      end
      logged(log).should be_empty
    end
  end

  it "runs the program, built unoptimized into out/run, with the arguments after --" do
    with_project do |root, log|
      ENV["FAKE_PROGRAM_STATUS"] = "3"
      zane(Zane::Commands::Run, ["--", "a", "--b"], root).should eq({3, "program ran with [a, --b]\n", ""})
      program = root / "out" / "run" / "demo#{EXE}"
      logged(log).should eq ["--build #{program} --kind application --package demo=#{root / "bin" / "demo"} --import demo:demo=demo"]
    end
  end

  it "runs the program named, and asks for a name when there are several" do
    with_project({"bin/demo/main.zn" => "package demo;\n", "bin/tool/main.zn" => "package tool;\n"}) do |root, log|
      expect_raises(Zane::UserError, "the project has 2 programs, demo, tool; name the one to run") do
        zane(Zane::Commands::Run, [] of String, root)
      end
      zane(Zane::Commands::Run, ["tool"], root)[0].should eq 0
      logged(log).should eq ["--build #{root / "out" / "run" / "tool#{EXE}"} --kind application --package tool=#{root / "bin" / "tool"} --import tool:tool=tool"]
    end
  end

  it "does not run a program that failed to build" do
    with_project do |root|
      ENV["FAKE_ZANEC_STATUS"] = "1"
      zane(Zane::Commands::Run, [] of String, root)[0].should eq 1
      Dir.children(root / "out" / "run").should be_empty
    end
  end

  it "rejects a stray argument" do
    with_project do |root|
      expect_raises(Zane::UserError, "unexpected argument extra") do
        zane(Zane::Commands::Check, ["extra"], root)
      end
      expect_raises(Zane::UserError, "unexpected argument extra") do
        zane(Zane::Commands::Build, ["--", "extra"], root)
      end
    end
  end

  it "builds each test package into out/test and runs it, then says how many passed" do
    with_project(LAYOUT) do |root, log|
      status, output, _ = zane(Zane::Commands::Test, ["--", "x"], root)
      status.should eq 0
      output.should eq <<-TEXT
        Testing test/gui/opengl/
        program ran with [x]
        Testing test/math/
        program ran with [x]
        2 test packages passed.

        TEXT
      logged(log).map(&.split(" --kind").first).should eq [
        "--build #{root / "out" / "test" / "gui.opengl#{EXE}"}",
        "--build #{root / "out" / "test" / "math#{EXE}"}",
      ]
    end
  end

  it "runs the test package named, with its own status" do
    with_project(LAYOUT) do |root, log|
      ENV["FAKE_PROGRAM_STATUS"] = "4"
      zane(Zane::Commands::Test, ["gui/opengl/"], root).should eq({4, "program ran with []\n", ""})
      logged(log).size.should eq 1
      expect_raises(Zane::UserError, "test/gui/ is no test package; the test packages are gui/opengl, math") do
        zane(Zane::Commands::Test, ["gui"], root)
      end
    end
  end

  it "says which test packages failed" do
    with_project(LAYOUT) do |root|
      ENV["FAKE_PROGRAM_STATUS"] = "1"
      status, output, _ = zane(Zane::Commands::Test, [] of String, root)
      status.should eq 1
      output.lines.last.should eq "2 of 2 test packages failed: gui/opengl, math"
    end
  end

  it "does not run a test package that failed to build" do
    with_project(LAYOUT) do |root|
      ENV["FAKE_ZANEC_STATUS"] = "1"
      zane(Zane::Commands::Test, ["math"], root).should eq({1, "", "fake compiler error\n"})
    end
  end

  it "refuses to test a project with no test package" do
    with_project do |root, log|
      expect_raises(Zane::UserError, "has no test package") do
        zane(Zane::Commands::Test, [] of String, root)
      end
      logged(log).should be_empty
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
