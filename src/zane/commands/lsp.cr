require "../compiler"
require "../errors"
require "../home"
require "../workspace"

module Zane::Commands
  # `zane lsp` (§2.8): the language server an editor starts. It runs the
  # compiler's own server, `zanec --lsp`, on this command's standard input
  # and output, and names this `zane` to it, so the server can run
  # `zane builds` for each project the editor opens.
  class Lsp
    def initialize(args : Array(String), @error : IO,
                   @dir : Path = Path[Dir.current], @toolchains : Path = Home.toolchains)
      raise UserError.new("unexpected argument #{args.first}\nusage: zane lsp") unless args.empty?
    end

    # The compiler of the project the editor started the server in, or,
    # outside any project, the newest one installed. A project whose
    # manifest is wrong is reported, as every other command reports it.
    def compiler : Compiler
      if root = project_root
        Compiler.locate(Workspace.load(root).zane_version, @toolchains)
      else
        Compiler.locate_newest(@toolchains)
      end
    end

    # The nearest directory, *@dir* or one above it, that holds a manifest.
    private def project_root : Path?
      dir = @dir.expand
      loop do
        return dir if File.file?(dir / Workspace::MANIFEST)
        return nil if dir.parent == dir
        dir = dir.parent
      end
    end

    def run : Int32
      compiler = self.compiler
      zane = Process.executable_path || raise UserError.new("cannot find this zane's own executable to name to the language server")
      process = begin
        Process.new(compiler.path, ["--lsp", "--zane", zane], input: Process::Redirect::Inherit,
          output: Process::Redirect::Inherit, error: Process::Redirect::Pipe)
      rescue error : IO::Error
        raise UserError.new("cannot run #{compiler.path}: #{error.message}")
      end
      # The server's log passes through to the editor, and its start is kept
      # to recognise a compiler with no server, which prints its usage.
      start = IO::Memory.new
      copied = Channel(Nil).new
      spawn do
        buffer = Bytes.new(4096)
        while (n = process.error.read(buffer)) > 0
          start.write(buffer[0, Math.min(n, 4096 - start.size)]) if start.size < 4096
          @error.write(buffer[0, n])
          @error.flush
        end
        copied.send(nil)
      end
      status = Compiler.exit_code(process.wait)
      copied.receive
      if status == 2 && start.to_s.starts_with?("usage: zanec")
        raise UserError.new("the compiler at #{compiler.path} has no language server; " \
                            "`zane toolchain update` installs the newest compiler release, which has one")
      end
      status
    end
  end
end
