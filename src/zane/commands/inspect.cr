require "./build"

module Zane::Commands
  # `zane inspect VIEW [PROGRAM] [--optimize] [--target TRIPLE]`
  # (docs/design/cli.md §4): one of the pinned compiler's debug views of a
  # program, printed. `decls`, `tst`, `cgt` and `ll` view the program's
  # build, given the packages `zane build` gives it, and `--optimize` and
  # `--target` show that build as `zane build` makes it. `cst` and `sst`
  # view one source file at a time, and are printed for every file of the
  # program package, in name order.
  class Inspect < ProjectCommand
    BUILD_VIEWS = %w(decls tst cgt ll)
    FILE_VIEWS  = %w(cst sst)

    @view : String? = nil
    @program : String? = nil
    @optimize = false
    @target : String? = nil

    def usage : String
      "usage: zane inspect cst|sst|decls|tst|cgt|ll [PROGRAM] [--optimize] [--target TRIPLE]"
    end

    private def options(p : OptionParser) : Nil
      p.on("--optimize", "Show the build an optimized build makes, as `zane build` does") { @optimize = true }
      p.on("--target TRIPLE", "The LLVM target triple to build for, instead of the host") { |v| @target = v }
    end

    private def positional(rest : Array(String)) : Nil
      view = rest.first? || raise UserError.new("inspect needs a view\n#{usage}")
      unless BUILD_VIEWS.includes?(view) || FILE_VIEWS.includes?(view)
        raise UserError.new("#{view} is no view; the views are #{(FILE_VIEWS + BUILD_VIEWS).join(", ")}")
      end
      raise UserError.new("inspect takes one program\n#{usage}") if rest.size > 2
      @view = view
      @program = rest[1]?
    end

    def run : Int32
      chosen = programs(@program)
      if chosen.size > 1
        raise UserError.new("the project has #{chosen.size} programs, #{chosen.map(&.name).join(", ")}; name the one to inspect")
      end
      program = chosen.first
      view = @view.not_nil!
      if FILE_VIEWS.includes?(view)
        if @optimize || @target
          raise UserError.new("#{view} views a source file, which is the same however it is built; --optimize and --target apply to #{BUILD_VIEWS.join(", ")}")
        end
        files(program, view)
      else
        args = ["--#{view}"]
        args.push("--target", @target.not_nil!) if @target
        args << "--optimize" if @optimize
        compiler.run(args + program_build(program), @output, @error)
      end
    end

    # The view of each source file directly in the program package, each
    # under its name when there are several.
    private def files(program : Layout::Program, view : String) : Int32
      sources = Dir.children(program.dir).select(&.ends_with?(".zn")).sort
      sources.each do |name|
        @output.puts "#{name}:" if sources.size > 1
        @output.flush
        status = compiler.run(["--#{view}", (program.dir / name).to_s], @output, @error)
        return status unless status == 0
      end
      0
    end
  end
end
