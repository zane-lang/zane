require "./version"
require "./coda"
require "./sha256"

module Zane::CLI
  USAGE = <<-TEXT
    usage: zane <command> [arguments]

    The commands are designed in docs/design/cli.md and arrive in phases.

      help       show this text
      version    show the version of zane
    TEXT

  # Runs one invocation and returns its exit status.
  def self.run(args : Array(String), stdout : IO = STDOUT, stderr : IO = STDERR) : Int32
    case args.first?
    when nil, "help", "-h", "--help"
      stdout.puts USAGE
      0
    when "version", "--version"
      stdout.puts "zane #{VERSION}"
      0
    else
      stderr.puts "zane: unknown command `#{args.first}`"
      stderr.puts USAGE
      2
    end
  end
end
