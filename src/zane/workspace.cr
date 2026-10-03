require "./errors"
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

    def name : String
      manifest.name
    end

    def kind : Project::Kind
      manifest.kind
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

    # Where the package's sources are (spec packages.md §2.1).
    def source_dir : Path
      root / "src"
    end

    # Where builds go.
    def out_dir : Path
      root / "out"
    end

    # A package is the `.zn` files directly in `src/`, and a subdirectory
    # holding one is an error (packages.md §2.1). The compiler only reads the
    # directory it is given, so `zane` is the one that can see a subdirectory.
    def check_sources : Nil
      unless Dir.exists?(source_dir)
        raise UserError.new("#{source_dir} does not exist; a project's sources go there")
      end
      Dir.each_child(source_dir) do |entry|
        dir = source_dir / entry
        next unless real_directory?(dir)
        if source = first_source(dir)
          raise UserError.new("#{source} is in a subdirectory of src/; a package's sources go directly in src/")
        end
      end
    end

    private def first_source(dir : Path) : Path?
      Dir.each_child(dir) do |entry|
        path = dir / entry
        return path if entry.ends_with?(".zn") && File.file?(path)
        if real_directory?(path) && (found = first_source(path))
          return found
        end
      end
      nil
    end

    # A directory that is not a symbolic link, so following one cannot loop.
    private def real_directory?(path : Path) : Bool
      File.info?(path, follow_symlinks: false).try(&.directory?) || false
    end
  end
end
