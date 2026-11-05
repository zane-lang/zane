require "./spec_helper"
require "./support/terminal"

private def wait_for_flushes(terminal : SpecTerminal, count : Int32) : Nil
  # Do not yield to the fiber scheduler: checksumming an archive does not
  # yield either. Bound the wait so a regression fails, not hangs.
  target = terminal.flushes + count
  deadline = Time.instant + 5.seconds
  while terminal.flushes < target && Time.instant < deadline
  end
  terminal.flushes.should be >= target
end

private def plain(terminal : SpecTerminal) : String
  terminal.to_s.gsub(/\e\[[0-9;]*[mK]/, "")
end

describe Zane::Progress do
  it "keeps animating while the caller does CPU-bound work, then clears the line" do
    with_terminal do |terminal|
      value = Zane::Progress.run(terminal) do |progress|
        progress.step("Verifying compiler v1.0")
        wait_for_flushes(terminal, 3)
        progress.step("Installing compiler v1.0")
        42
      end
      value.should eq 42
      text = plain(terminal)
      frames = Zane::Progress::FRAMES
      text.should contain "#{frames[0]} Verifying compiler v1.0"
      text.should contain "#{frames[1]} Verifying compiler v1.0"
      text.should contain "#{frames[2]} Verifying compiler v1.0"
      terminal.to_s.should end_with "\r\e[K"
    end
  end

  it "keeps each finished step on its own line with how long it took" do
    with_terminal do |terminal|
      Zane::Progress.run(terminal) do |progress|
        progress.step("Looking up compiler v1.0")
        progress.done("Found compiler v1.0")
        progress.step("Checking the toolchain")
      end
      lines = plain(terminal).split('\n')
      done = Regex.escape(Zane::Progress::DONE)
      lines[0].should match /\r#{done} Found compiler v1\.0 \(\d+\.\ds\)\z/
      # The step still running when the block returns is done too, under its
      # own label.
      lines[1].should match /\r#{done} Checking the toolchain \(\d+\.\ds\)\z/
      lines[2].should eq "\r"
    end
  end

  it "draws a progress bar with the amount done, then reports the bytes moved" do
    with_terminal do |terminal|
      ENV["COLUMNS"] = "120"
      begin
        moved = Atomic(Int64).new(0)
        Zane::Progress.run(terminal) do |progress|
          progress.step("Downloading compiler v1.0", 2_000_000_i64) { moved.get }
          moved.set(1_000_000)
          wait_for_flushes(terminal, 2)
          moved.set(2_000_000)
          progress.done("Downloaded compiler v1.0")
        end
      ensure
        ENV.delete("COLUMNS")
      end
      text = plain(terminal)
      bar = "#{Zane::Progress::FULL.to_s * 12}#{Zane::Progress::EMPTY.to_s * 12}"
      text.should contain "Downloading compiler v1.0  #{bar}  50%  1.0 / 2.0 MB"
      text.should match /Downloaded compiler v1\.0 \(2\.0 MB in \d+\.\ds(, [0-9.]+ [KMGT]?B\/s)?\)\n/
    end
  end

  it "leaves details out rather than wrapping a narrow terminal" do
    with_terminal do |terminal|
      ENV["COLUMNS"] = "40"
      begin
        Zane::Progress.run(terminal) do |progress|
          progress.step("Downloading compiler v1.0", 2_000_000_i64) { 500_000_i64 }
          wait_for_flushes(terminal, 1)
          progress.step("Extracting a toolchain with a very long name indeed")
          wait_for_flushes(terminal, 1)
        end
      ensure
        ENV.delete("COLUMNS")
      end
      redrawn = plain(terminal).split(/[\r\n]/).select { |line| Zane::Progress::FRAMES.includes?(line[0]?) }
      redrawn.should_not be_empty
      redrawn.each { |line| line.size.should be < 40 }
      steps = redrawn.map(&.[2..])
      steps.should contain "Downloading compiler v1.0  25%"
      steps.should contain "Extracting a toolchain with a very l…"
    end
  end

  it "marks the failed step before propagating an installation failure" do
    with_terminal do |terminal|
      expect_raises(Zane::UserError, "download failed") do
        Zane::Progress.run(terminal) do |progress|
          progress.step("Downloading compiler v1.0")
          raise Zane::UserError.new("download failed")
        end
      end
      plain(terminal).should end_with "\r#{Zane::Progress::FAILED} Downloading compiler v1.0\n\r"
      terminal.to_s.should end_with "\r\e[K"
    end
  end

  it "uses no colours when NO_COLOR is set" do
    with_terminal do |terminal|
      ENV["NO_COLOR"] = "1"
      begin
        Zane::Progress.run(terminal) { |progress| progress.step("Downloading") }
      ensure
        ENV.delete("NO_COLOR")
      end
      terminal.to_s.should_not match /\e\[[0-9;]*m/
      terminal.to_s.should contain "#{Zane::Progress::DONE} Downloading"
    end
  end

  it "counts items, with no rate, and names how many it did" do
    with_terminal do |terminal|
      ENV["COLUMNS"] = "120"
      begin
        rewritten = Atomic(Int64).new(0)
        Zane::Progress.run(terminal) do |progress|
          progress.step("Rewriting math v1.0's objects", 4_i64, "files") { rewritten.get }
          rewritten.set(1)
          wait_for_flushes(terminal, 2)
          rewritten.set(4)
          progress.done
        end
      ensure
        ENV.delete("COLUMNS")
      end
      text = plain(terminal)
      text.should match /Rewriting math v1\.0's objects  [^ ]+  25%  1 \/ 4 files(\s|\z)/
      text.should_not contain "B/s"
      text.should match /#{Regex.escape(Zane::Progress::DONE)} Rewriting math v1\.0's objects \(4 files in \d+\.\ds\)\n/
    end
  end

  it "adds a note as a finished line of its own, with no time, after the step before it" do
    with_terminal do |terminal|
      Zane::Progress.run(terminal) do |progress|
        progress.step("Fetching math v1.0")
        progress.note("1 dependency's objects from the cache: math v1.0")
      end
      lines = plain(terminal).split('\n')
      done = Regex.escape(Zane::Progress::DONE)
      lines[0].should match /\r#{done} Fetching math v1\.0 \(\d+\.\ds\)\z/
      lines[1].should end_with "\r#{Zane::Progress::DONE} 1 dependency's objects from the cache: math v1.0"
    end
  end

  it "has written a step's line by the time it is marked done, so what the command prints comes after" do
    with_terminal do |terminal|
      Zane::Progress.run(terminal) do |progress|
        progress.step("Fetching math v1.0")
        progress.done("Fetched math v1.0")
        # No waiting: the line is there already.
        plain(terminal).should contain "#{Zane::Progress::DONE} Fetched math v1.0"
        progress.note("from the cache")
        plain(terminal).should end_with "#{Zane::Progress::DONE} from the cache\n"
      end
    end
  end

  it "holds a program's output until its step is done, and marks the step failed when the program fails" do
    with_terminal do |terminal|
      output = IO::Memory.new
      Zane::Progress.run(terminal) do |progress|
        progress.run("Compiling bin/app/", "Compiled bin/app/", output, terminal) do |stdout, err|
          stdout.puts "built"
          err.puts "warning: unused"
          plain(terminal).should_not contain "warning"
          0
        end.should eq 0
        progress.run("Compiling bin/other/", "Compiled bin/other/", output, terminal) do |_, err|
          err.puts "error: no main"
          1
        end.should eq 1
      end
      output.to_s.should eq "built\n"
      text = plain(terminal)
      text.should match /#{Regex.escape(Zane::Progress::DONE)} Compiled bin\/app\/ \(\d+\.\ds\)\nwarning: unused\n/
      text.should contain "#{Zane::Progress::FAILED} Compiling bin/other/\nerror: no main\n"
    end
  end

  it "runs a program straight to its streams when nothing is shown" do
    output, error = IO::Memory.new, IO::Memory.new
    Zane::Progress.run(error) do |progress|
      progress.run("Compiling", "Compiled", output, error) do |stdout, err|
        stdout.should be output
        err.should be error
        0
      end
    end
    error.to_s.should eq ""
  end

  it "is the current display while it runs, shared by a nested run for the same output" do
    with_terminal do |terminal|
      outer = Zane::Progress.current
      Zane::Progress.run(terminal) do |progress|
        Zane::Progress.current.should be progress
        Zane::Progress.run(terminal) { |inner| inner.should be progress }
        Zane::Progress.current.step("Fetching")
      end
      Zane::Progress.current.should be outer
      Zane::Progress.current.enabled?.should be_false
      plain(terminal).should contain "#{Zane::Progress::DONE} Fetching"
    end
  end

  it "leaves redirected output untouched" do
    output = IO::Memory.new
    Zane::Progress.run(output) do |progress|
      progress.step("Downloading")
      progress.done
    end
    output.to_s.should eq ""
  end

  it "leaves dumb terminals untouched" do
    with_terminal do |terminal|
      ENV["TERM"] = "dumb"
      Zane::Progress.run(terminal) { |progress| progress.step("Downloading") }
      terminal.to_s.should eq ""
    end
  end

  it "has nothing to clear if installation fails before the first step" do
    with_terminal do |terminal|
      expect_raises(Zane::UserError) do
        Zane::Progress.run(terminal) { raise Zane::UserError.new("invalid version") }
      end
      terminal.to_s.should eq ""
    end
  end
end
