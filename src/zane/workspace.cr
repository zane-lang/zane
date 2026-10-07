require "./errors"
require "./layout"
require "./manifest"
require "./project"

module Zane
  # A project on disk: the directory holding its `zane.coda`, and what the
  # manifest says a build needs.
  record Workspace, manifest : Manifest do
    MANIFEST = Manifest::FILE

    # The project *dir* is in: the nearest directory, *dir* itself or one
    # above it, that holds a manifest.
    def self.find(dir : Path) : Workspace
      dir = dir.expand
      loop do
        return load(dir) if File.file?(dir / MANIFEST)
        parent = dir.parent
        if parent == dir
          raise UserError.new("no #{MANIFEST} in this directory or any above it; create a project with `zane init`")
        end
        dir = parent
      end
    end

    def self.load(root : Path) : Workspace
      manifest = Manifest.load(root)
      unless manifest.zane_version
        raise UserError.new("#{root / MANIFEST} has no `zane-version` field")
      end
      new(manifest)
    end

    def root : Path
      manifest.root
    end

    # What the project is called where a person reads it: its directory.
    def title : String
      root.basename
    end

    # The compiler release that builds the project.
    def zane_version : String
      manifest.zane_version.not_nil!
    end

    # The compiler pin: its tag, and the commit the lock file's `zane` row
    # names (spec dependencies.md §14).
    def toolchain : {String, String}
      {zane_version, manifest.resolutions[Manifest::COMPILER_KEY].commit}
    end

    # The project's packages, read from its directories and held to their
    # rules (spec packages.md §2).
    def layout : Layout
      Layout.new(root)
    end

    # Where builds go.
    def out_dir : Path
      root / "out"
    end

    # Each line of the project's sources, in every package, that imports one
    # of *names*, in any of the import forms (spec packages.md §3.3), as a
    # path from the root and a line number.
    def importers(names : Array(String)) : Array({String, Int32})
      return [] of {String, Int32} if names.empty?
      import = /^\s*import\s+(#{names.map { |n| Regex.escape(n) }.join("|")})(?![A-Za-z0-9_])/
      found = [] of {String, Int32}
      {"lib", "bin", Project::TEST_PACKAGE}.each { |dir| scan(root / dir, import, found) }
      found
    end

    private def scan(dir : Path, import : Regex, found : Array({String, Int32})) : Nil
      return unless File.info?(dir, follow_symlinks: false).try(&.directory?)
      Dir.children(dir).sort!.each do |name|
        path = dir / name
        if name.ends_with?(".zn") && File.file?(path)
          File.read_lines(path).each_with_index(1) do |line, number|
            found << {path.relative_to(root).to_posix.to_s, number} if import.matches?(line)
          end
        else
          scan(path, import, found)
        end
      end
    end
  end
end
