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
  # row together. The dependencies that compiler cannot build as they are
  # pinned move with it, each to its newest version the compiler builds.
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

      # The release just installed, never `ZANE_COMPILER` or one on PATH: the
      # objects are cached under its pin, and the pin is what gets written.
      installed = Compiler.new((@toolchains / release.tag / "bin" / Compiler::EXECUTABLE).to_s)
      moved = fetch_moving(ws.manifest.with_compiler(release.tag, release.commit), release.tag, installed)
      ProjectFiles.change(ws.root,
        ->(doc : Coda::Doc) {
          doc.root["zane-version"] = release.tag
          moved.each { |_, d, _| ProjectFiles.deps(doc, d.test)[d.key]["version"] = d.version }
          nil
        },
        ->(doc : Coda::Doc) {
          table = ProjectFiles.resolutions(doc)
          row = table[Manifest::COMPILER_KEY]
          row["url"] = CompilerRelease::URL
          row["commit"] = release.commit
          moved.each { |_, d, r| table[d.key]["url"] = r.url; table[d.key]["commit"] = r.commit }
          nil
        })
      @output.puts "Updated zane #{current} -> #{release.tag} (commit #{release.commit[0, 12]})."
      moved.each do |old, new, resolution|
        @output.puts "Updated #{new.key} #{old.version} -> #{new.version} (commit #{resolution.commit[0, 12]}), " \
                     "the newest version compiler #{release.tag} builds."
      end
      0
    end

    # Fetches *manifest*'s graph with *compiler*, the release *tag*. While the
    # graph holds a package the compiler cannot build, each of the project's
    # own dependencies that brings one in moves to its newest version the
    # compiler builds, so that the compiler and the dependencies that need it
    # move in one change. A dependency moves once at most, and when none can
    # move, the error stands. Returns each dependency moved, as it was and
    # as it is now, with its new lock row.
    private def fetch_moving(manifest : Manifest, tag : String,
                             compiler : Compiler) : Array({Dependency, Dependency, Resolution})
      moved = [] of {Dependency, Dependency, Resolution}
      loop do
        fetch(manifest, compiler)
        return moved
      rescue error : Graph::Unbuildable
        moves = error.keys.compact_map do |key|
          dep = manifest.dependency?(key).not_nil!
          next if dep.path? || moved.any? { |old, _, _| old.key == key }
          buildable(dep, manifest.resolutions[key], tag)
        end
        raise error if moves.empty?
        moves.each do |old, new, resolution|
          manifest = manifest.with_dependency(new, resolution)
          moved << {old, new, resolution}
        end
      end
    end

    # *dep* moved to its newest version after the one pinned, *locked*, whose
    # `zane-version` the compiler release *tag* builds, with its lock row; nil
    # when it has none. Versions are read newest first, and one whose
    # manifest cannot be read is passed over.
    private def buildable(dep : Dependency, locked : Resolution, tag : String) : {Dependency, Dependency, Resolution}?
      url = PackageUrl.parse(locked.url)
      tags = Git.tags(url.url)
      pinned = tag_version(dep.version)
      candidates = tags.keys.select do |t|
        version = tag_version(t)
        version && PackageUrl.tag_error(t).nil? && (pinned.nil? || (version <=> pinned) > 0)
      end
      candidates.sort_by { |t| tag_version(t).not_nil! }.reverse_each do |candidate|
        commit = tags[candidate]
        manifest = begin
          Manifest.load(CacheEntry.new(url, candidate).source(commit))
        rescue error : UserError
          raise error if error.message.try(&.starts_with?("security error"))
          next
        end
        if CompilerRelease.builds?(tag, manifest.zane_version)
          return {dep, dep.copy_with(version: candidate), Resolution.new(url.url, commit)}
        end
      end
      nil
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
