require "./coda"
require "./errors"
require "./project"

module Zane
  # A project on disk: the directory holding its `zane.coda`, and what the
  # manifest says a build needs.
  record Workspace, root : Path, name : String, kind : Project::Kind, zane_version : String do
    MANIFEST = "zane.coda"

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
      path = root / MANIFEST
      Coda::Doc.parse_file(path) do |doc|
        manifest = doc.root
        name = field(manifest, "name", path)
        unless Project.valid_name?(name)
          raise UserError.new("#{path}: `#{name}` is not a package name")
        end
        kind = case value = field(manifest, "kind", path)
               when "application" then Project::Kind::Application
               when "library"     then Project::Kind::Library
               else
                 raise UserError.new("#{path}: `kind` is `#{value}`; it is `application` or `library`")
               end
        if (deps = manifest["deps"]?) && !(deps.is_a?(Coda::KeyedTable) && deps.empty?)
          raise UserError.new("#{path}: dependencies are not supported yet, so `deps` stays empty")
        end
        new(root, name, kind, field(manifest, "zane-version", path))
      end
    rescue error : Coda::Error
      raise UserError.new("#{path}: #{error.message}")
    end

    private def self.field(manifest : Coda::Block, key : String, path : Path) : String
      node = manifest[key]? || raise UserError.new("#{path} has no `#{key}` field")
      node.as?(Coda::StringNode).try(&.value) || raise UserError.new("#{path}: `#{key}` is not a single value")
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
        next unless File.directory?(dir)
        if source = first_source(dir)
          raise UserError.new("#{source} is in a subdirectory of src/; a package's sources go directly in src/")
        end
      end
    end

    private def first_source(dir : Path) : Path?
      Dir.each_child(dir) do |entry|
        path = dir / entry
        return path if entry.ends_with?(".zn") && File.file?(path)
        if File.directory?(path) && (found = first_source(path))
          return found
        end
      end
      nil
    end
  end
end
