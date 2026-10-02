require "./version"
require "./errors"
require "./commands/build"
require "./commands/init"

module Zane::CLI
  USAGE = <<-TEXT
    usage: zane <command> [arguments]

      init [dir]   create a project in dir, or in the current directory
      check        check the project without building it
      build        build the program into out/
      run          build the program, then run it
      clean        delete out/
      help         show this text
      version      show the version of zane

    The commands still to come are designed in docs/design/cli.md.
    TEXT

  # Runs one invocation and returns its exit status. Questions are asked only
  # when *interactive*, which is true when standard input is a terminal.
  def self.run(args : Array(String), stdout : IO = STDOUT, stderr : IO = STDERR,
               stdin : IO = STDIN, interactive : Bool = STDIN.tty?) : Int32
    case args.first?
    when nil, "help", "-h", "--help"
      stdout.puts USAGE
    when "version", "--version"
      stdout.puts "zane #{VERSION}"
    when "init"
      Commands::Init.new(args[1..], stdin, stdout, interactive).run
    when "check" then return Commands::Check.new(args[1..], stdout, stderr).run
    when "build" then return Commands::Build.new(args[1..], stdout, stderr).run
    when "run"   then return Commands::Run.new(args[1..], stdout, stderr).run
    when "clean" then return Commands::Clean.new(args[1..], stdout, stderr).run
    else
      stderr.puts "zane: unknown command `#{args.first}`"
      stderr.puts USAGE
      return 2
    end
    0
  rescue e : UserError
    stderr.puts "zane: #{e.message}"
    1
  end
end
