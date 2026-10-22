require "../toolchain"
require "../install_progress"
require "./deps"

module Zane::Commands
  # `zane toolchain install [tag]` and `zane toolchain update [tag]` (§4).
  class Toolchain
    USAGE = "usage: zane toolchain install [vMAJOR.MINOR] | zane toolchain update [vMAJOR.MINOR] [--accept-tag-move]"

    def initialize(@args : Array(String), @output : IO, @error : IO)
    end

    def run : Int32
      case @args.first?
      when "install"
        raise UserError.new(USAGE) unless @args.size <= 2
        release = InstallProgress.run(@error) do |progress|
          Zane::Toolchain.install(@args[1]?, progress: ->progress.stage(String))
        end
        @output.puts "Zane toolchain #{release.tag} is installed in #{Home.toolchains / release.tag}."
        0
      when "update"
        ToolchainUpdate.new(@args[1..], @output, @error).run
      else
        raise UserError.new(USAGE)
      end
    end
  end

  # `zane toolchain update [tag] [--accept-tag-move]` (§4): installs the
  # compiler release named, or else the newest of the project's major, and
  # moves the project's compiler pin to it, `zane-version` and the `zane` lock
  # row together.
  class ToolchainUpdate < EditCommand
    @accept_tag_move = false

    def usage : String
      "usage: zane toolchain update [vMAJOR.MINOR] [--accept-tag-move]"
    end

    def arity : Range(Int32, Int32)
      0..1
    end

    private def options(p : OptionParser) : Nil
      p.on("--accept-tag-move", "Trust the commit the compiler tag points to now, though the lock file pins another") { @accept_tag_move = true }
    end

    def run : Int32
      ws = workspace
      current, locked = ws.toolchain
      tag = @args[0]? || newest_in_major(current)
      release = InstallProgress.run(@error) do |progress|
        Zane::Toolchain.install(tag, @toolchains,
          vet: ->(r : CompilerRelease) { check_tag_move(r, locked) if r.tag == current; nil },
          progress: ->progress.stage(String))
      end
      if release.tag == current && same_commit?(release.commit, locked)
        @output.puts "The project is already built by #{current}, which is installed; nothing changed."
        return 0
      end

      resolve(ws.manifest.with_compiler(release.tag, release.commit))
      ProjectFiles.change(ws.root,
        ->(doc : Coda::Doc) { doc.root["zane-version"] = release.tag; nil },
        ->(doc : Coda::Doc) {
          row = ProjectFiles.resolutions(doc)[Manifest::COMPILER_KEY]
          row["url"] = CompilerRelease::URL
          row["commit"] = release.commit
          nil
        })
      @output.puts "Updated zane #{current} -> #{release.tag} (commit #{release.commit[0, 12]})."
      0
    end

    # The newest compiler release of *current*'s major. Moving to another
    # major changes what the project's code must be, so it is done only by
    # naming the release (spec dependencies.md §2.3, §14).
    private def newest_in_major(current : String) : String
      major = CompilerRelease.version(current).not_nil![0]
      CompilerRelease.newest(Zane::Toolchain.releases.call, major) ||
        raise UserError.new("#{CompilerRelease::URL} has no release of major #{major}; name the release to move to")
    end

    # A compiler tag that now points to another commit than the lock pins has
    # moved, which is trusted only when asked (spec dependencies.md §4, §14).
    private def check_tag_move(release : CompilerRelease, locked : String) : Nil
      return if @accept_tag_move || same_commit?(release.commit, locked)
      raise UserError.new("security error: #{CompilerRelease::URL} tag #{release.tag} is commit #{release.commit}, " \
                          "but the lock file pins #{locked}. The tag has moved; to trust the new commit, run " \
                          "`zane toolchain update #{release.tag} --accept-tag-move`")
    end
  end
end
