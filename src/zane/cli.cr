require "./version"
require "./errors"
require "./commands/build"
require "./commands/cache"
require "./commands/deps"
require "./commands/init"
require "./commands/toolchain"

module Zane::CLI
  USAGE = <<-TEXT
    usage: zane <command> [arguments]

      init [dir]             create a project in dir, or in the current directory
      check                  check the project without building it
      build                  build the program into out/
      run                    build the program, then run it
      test [-- ARGS]         build a library's test package in test/, then run it
      clean                  delete out/
      add <url> [tag]        depend on the library at url, at its newest tag or the one named;
                             with --test, for the test package alone
      remove <key>           stop depending on key
      update [key [tag]]     move key, or every dependency, to its newest tag or the one named
      dev <key> <path>       compile key from the local project at path
      dev off <key>          link key's release again
      remap <url>            link the interchangeable versions of the package at url as one
      unremap <url>          link its versions side by side again
      fetch                  fetch what a build needs, so it can then run offline
      tree [--test]          show the packages the project, or its test build, depends on
      cache list|path|clean  show, locate or empty the package cache
      toolchain install [version]  install the latest compiler release, or the version named
      help                   show this text
      version                show the version of zane

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
    when "check"     then return Commands::Check.new(args[1..], stdout, stderr).run
    when "build"     then return Commands::Build.new(args[1..], stdout, stderr).run
    when "run"       then return Commands::Run.new(args[1..], stdout, stderr).run
    when "test"      then return Commands::Test.new(args[1..], stdout, stderr).run
    when "clean"     then return Commands::Clean.new(args[1..], stdout, stderr).run
    when "add"       then return Commands::Add.new(args[1..], stdout, stderr).run
    when "fetch"     then return Commands::Fetch.new(args[1..], stdout, stderr).run
    when "remove"    then return Commands::Remove.new(args[1..], stdout, stderr).run
    when "update"    then return Commands::Update.new(args[1..], stdout, stderr).run
    when "dev"       then return Commands::Dev.new(args[1..], stdout, stderr).run
    when "remap"     then return Commands::Remap.new(true, args[1..], stdout, stderr).run
    when "unremap"   then return Commands::Remap.new(false, args[1..], stdout, stderr).run
    when "tree"      then return Commands::Tree.new(args[1..], stdout, stderr).run
    when "cache"     then return Commands::Cache.new(args[1..], stdout, stderr).run
    when "toolchain" then return Commands::Toolchain.new(args[1..], stdout, stderr).run
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
