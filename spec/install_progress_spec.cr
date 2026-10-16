require "./spec_helper"
require "./support/terminal"

describe Zane::InstallProgress do
  it "keeps animating while the caller does CPU-bound work, then clears the line" do
    with_terminal do |terminal|
      value = Zane::InstallProgress.run(terminal) do |progress|
        progress.stage("Verifying compiler v1.0")
        # Do not yield to the fiber scheduler: checksumming an archive does
        # not yield either. Bound the wait so a regression fails, not hangs.
        deadline = Time.instant + 5.seconds
        while terminal.flushes < 3 && Time.instant < deadline
        end
        terminal.flushes.should be >= 3
        progress.stage("Installing compiler v1.0")
        42
      end
      value.should eq 42
      text = terminal.to_s
      text.should contain "| Verifying compiler v1.0"
      text.should contain "/ Verifying compiler v1.0"
      text.should contain "- Verifying compiler v1.0"
      text.should contain "Installing compiler v1.0"
      text.should end_with "\r\e[K"
    end
  end

  it "clears the line before propagating an installation failure" do
    with_terminal do |terminal|
      expect_raises(Zane::UserError, "download failed") do
        Zane::InstallProgress.run(terminal) do |progress|
          progress.stage("Downloading compiler v1.0")
          raise Zane::UserError.new("download failed")
        end
      end
      terminal.to_s.should contain "Downloading compiler v1.0"
      terminal.to_s.should end_with "\r\e[K"
    end
  end

  it "leaves redirected output untouched" do
    output = IO::Memory.new
    Zane::InstallProgress.run(output) { |progress| progress.stage("Downloading") }
    output.to_s.should eq ""
  end

  it "leaves dumb terminals untouched" do
    with_terminal do |terminal|
      ENV["TERM"] = "dumb"
      Zane::InstallProgress.run(terminal) { |progress| progress.stage("Downloading") }
      terminal.to_s.should eq ""
    end
  end

  it "has nothing to clear if installation fails before the first stage" do
    with_terminal do |terminal|
      expect_raises(Zane::UserError) do
        Zane::InstallProgress.run(terminal) { raise Zane::UserError.new("invalid version") }
      end
      terminal.to_s.should eq ""
    end
  end
end
