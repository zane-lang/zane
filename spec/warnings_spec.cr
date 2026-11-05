require "./spec_helper"
require "../src/zane/warnings"

describe Zane::Warnings do
  warning = "File \"a.c\", line 1, characters 2-2:\n1 | x\n  | ^\nWarning: unused\n"
  error = "File \"a.c\", line 1, characters 2-2:\n1 | x\n  | ^\nError: wrong\n"

  it "shows a warning once across runs" do
    io = IO::Memory.new
    w = Zane::Warnings.new(io)
    w << "building\n" << warning
    w.flush
    w << warning << "done\n"
    w.flush
    io.to_s.should eq("building\n#{warning}done\n")
  end

  it "shows every error" do
    io = IO::Memory.new
    w = Zane::Warnings.new(io)
    w << error << error
    w.flush
    io.to_s.should eq(error + error)
  end

  it "passes a partial line and an unfinished block on at a flush" do
    io = IO::Memory.new
    w = Zane::Warnings.new(io)
    w << "File \"a.c\", line 1:\nhalf"
    w.flush
    io.to_s.should eq("File \"a.c\", line 1:\nhalf")
  end
end
