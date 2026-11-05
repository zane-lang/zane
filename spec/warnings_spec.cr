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

  it "passes on a block that ends in neither, and still drops a warning shown after it" do
    io = IO::Memory.new
    w = Zane::Warnings.new(io)
    w << warning << "File \"b.c\", line 2:\nNote: aside\n" << warning
    w.flush
    io.to_s.should eq("#{warning}File \"b.c\", line 2:\nNote: aside\n")
  end

  it "passes a partial line and an unfinished block on at a flush" do
    io = IO::Memory.new
    w = Zane::Warnings.new(io)
    w << "File \"a.c\", line 1:\nhalf"
    w.flush
    io.to_s.should eq("File \"a.c\", line 1:\nhalf")
  end
end
