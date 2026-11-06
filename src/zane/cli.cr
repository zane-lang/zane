require "./version"
require "./errors"
require "./progress"
require "./commands/build"
require "./commands/cache"
require "./commands/deps"
require "./commands/init"
require "./commands/inspect"
require "./commands/self"
require "./commands/toolchain"

module Zane::CLI
  USAGE = <<-TEXT
    usage: zane <command> [arguments]

      init [dir]             create a project in dir, or in the current directory
      check                  check the project without building it
      build [program]        build every program in bin/, or the one named, into out/
      run [program]          build a program, then run it
      test [test]            build and run every test package in test/, or the one named
      clean                  delete out/
      inspect <view> [program]  print the compiler's view of a program: cst, sst, decls,
                             tst, cgt or ll; the last four also take --optimize and
                             --target TRIPLE, as zane build does
      add <url> [tag]        depend on the library at url, at its newest tag or the one named;
                             with --test, for the test package alone; with --from-source,
                             compiled here, which also switches a library already added
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
      toolchain update [version]   install it, and build the project with it from now on
      self update [version]  replace this zane with the latest release, or the version named
      help                   show this text
      version                show the version of zane

    The commands still to come are designed in docs/design/cli.md.
    TEXT

  # Runs one invocation and returns its exit status. Questions are asked only
  # when *interactive*, which is true when standard input is a terminal.
  def self.run(args : Array(String), stdout : IO = STDOUT, stderr : IO = STDERR,
               stdin : IO = STDIN, interactive : Bool = STDIN.tty?) : Int32
    # One display shows the slow steps of whichever command runs.
    Progress.run(stderr) do
      case args.first?
      when nil, "help", "-h", "--help"
        stdout.puts USAGE
        0
      when "version", "--version"
        stdout.puts "zane #{VERSION}"
        0
      when "init"
        Commands::Init.new(args[1..], stdin, stdout, interactive).run
        0
      when "check"     then Commands::Check.new(args[1..], stdout, stderr).run
      when "build"     then Commands::Build.new(args[1..], stdout, stderr).run
      when "run"       then Commands::Run.new(args[1..], stdout, stderr).run
      when "test"      then Commands::Test.new(args[1..], stdout, stderr).run
      when "clean"     then Commands::Clean.new(args[1..], stdout, stderr).run
      when "inspect"   then Commands::Inspect.new(args[1..], stdout, stderr).run
      when "add"       then Commands::Add.new(args[1..], stdout, stderr).run
      when "fetch"     then Commands::Fetch.new(args[1..], stdout, stderr).run
      when "remove"    then Commands::Remove.new(args[1..], stdout, stderr).run
      when "update"    then Commands::Update.new(args[1..], stdout, stderr).run
      when "dev"       then Commands::Dev.new(args[1..], stdout, stderr).run
      when "remap"     then Commands::Remap.new(true, args[1..], stdout, stderr).run
      when "unremap"   then Commands::Remap.new(false, args[1..], stdout, stderr).run
      when "tree"      then Commands::Tree.new(args[1..], stdout, stderr).run
      when "cache"     then Commands::Cache.new(args[1..], stdout, stderr).run
      when "toolchain" then Commands::Toolchain.new(args[1..], stdout, stderr).run
      when "self"      then Commands::SelfCommand.new(args[1..], stdout, stderr).run
      else
        stderr.puts "zane: unknown command `#{args.first}`"
        stderr.puts USAGE
        2
      end
    end
  rescue e : UserError
    stderr.puts "zane: #{e.message}"
    1
  end
end
