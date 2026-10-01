require "./spec_helper"

private def run(*args)
  stdout, stderr = IO::Memory.new, IO::Memory.new
  status = Zane::CLI.run(args.to_a, stdout, stderr)
  {status, stdout.to_s, stderr.to_s}
end

describe Zane::CLI do
  it "prints its version" do
    run("--version").should eq({0, "zane #{Zane::VERSION}\n", ""})
  end

  it "rejects an unknown command" do
    status, _, err = run("frobnicate")
    status.should eq 2
    err.should contain "unknown command `frobnicate`"
  end
end
