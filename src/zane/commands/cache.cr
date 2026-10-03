require "file_utils"
require "../errors"
require "../home"

module Zane::Commands
  # `zane cache list`, `zane cache path` and `zane cache clean [--stale]`
  # (docs/design/cli.md §4): the package cache every project shares (spec
  # dependencies.md §7).
  class Cache
    USAGE = "usage: zane cache list | path | clean [--stale]"

    # What an interrupted fetch leaves: a part made beside where it goes, not
    # yet renamed into place.
    PARTIAL = /\A\..+\.[0-9a-f]{8}\z/

    def initialize(@args : Array(String), @output : IO, @error : IO, @dir : Path = Home.packages)
    end

    def run : Int32
      case @args
      when ["list"]             then list
      when ["path"]             then @output.puts @dir
      when ["clean"]            then clean
      when ["clean", "--stale"] then clean_stale
      else                           raise UserError.new(USAGE)
      end
      0
    end

    # Each version in the cache, with the targets its objects are ready for
    # and the space it takes.
    private def list : Nil
      entries = versions(@dir)
      if entries.empty?
        @output.puts "The package cache, #{@dir}, is empty."
        return
      end
      entries.each do |entry|
        package = entry.parent.relative_to(@dir).to_posix
        targets = ready_targets(entry)
        @output.puts "#{package} #{entry.basename}  #{targets.empty? ? "source only" : targets.join(", ")}  #{size(entry).humanize_bytes}"
      end
    end

    private def clean : Nil
      freed = Dir.exists?(@dir) ? size(@dir) : 0_i64
      FileUtils.rm_rf(@dir)
      @output.puts "Emptied the package cache, #{@dir}: #{freed.humanize_bytes} freed."
    end

    # Removes what no build can use: the parts an interrupted fetch left,
    # and rewritten objects without the record that makes them ready.
    private def clean_stale : Nil
      freed = 0_i64
      stale(@dir).each do |path|
        freed += size(path)
        FileUtils.rm_rf(path)
      end
      @output.puts "Removed what interrupted fetches left in #{@dir}: #{freed.humanize_bytes} freed."
    end

    # The directories of single versions under *dir*: those holding the
    # checkout `src/`, which every version has.
    private def versions(dir : Path) : Array(Path)
      found = [] of Path
      return found unless Dir.exists?(dir)
      Dir.children(dir).sort!.each do |name|
        path = dir / name
        next if PARTIAL.matches?(name) || !real_dir?(path)
        if real_dir?(path / "src")
          found << path
        else
          found.concat(versions(path))
        end
      end
      found
    end

    # The targets whose rewritten objects are ready: those with a record.
    private def ready_targets(entry : Path) : Array(String)
      build = entry / "build"
      return [] of String unless Dir.exists?(build)
      Dir.children(build).select { |n| n.ends_with?(".coda") && real_dir?(build / n.rchop(".coda")) }.map(&.rchop(".coda")).sort!
    end

    private def stale(dir : Path) : Array(Path)
      found = partials(dir)
      versions(dir).each do |entry|
        build = entry / "build"
        next unless Dir.exists?(build)
        Dir.children(build).sort!.each do |name|
          path = build / name
          found << path if real_dir?(path) && !PARTIAL.matches?(name) && !File.file?(build / "#{name}.coda")
        end
      end
      found
    end

    private def partials(dir : Path) : Array(Path)
      found = [] of Path
      return found unless Dir.exists?(dir)
      Dir.children(dir).sort!.each do |name|
        path = dir / name
        if PARTIAL.matches?(name)
          found << path
        elsif real_dir?(path)
          found.concat(partials(path))
        end
      end
      found
    end

    private def size(path : Path) : Int64
      info = File.info?(path, follow_symlinks: false) || return 0_i64
      return info.size.to_i64 unless info.directory?
      Dir.children(path).sum(0_i64) { |name| size(path / name) }
    end

    private def real_dir?(path : Path) : Bool
      File.info?(path, follow_symlinks: false).try(&.directory?) || false
    end
  end
end
