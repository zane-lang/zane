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

    # Where a library's test package is (spec packages.md §7.1).
    def test_dir : Path
      root / Manifest::TEST_PACKAGE
    end

    # Whether the project has a test package: a `.zn` file directly in
    # `test/`.
    def tests? : Bool
      Dir.exists?(test_dir) && Dir.children(test_dir).any? { |e| e.ends_with?(".zn") && File.file?(test_dir / e) }
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

    # The test package keeps the rules of `src/`, and only a library has one
    # (packages.md §7.1). Its name and the keys each name one package in a
    # test build, and `src/` imports no `test-deps` key (§7.3).
    def check_tests : Nil
      return unless Dir.exists?(test_dir)
      if kind.application?
        if source = first_source(test_dir)
          raise UserError.new("#{source} is in test/, but an application has no test package; only a library does")
        end
        return
      end
      Dir.each_child(test_dir) do |entry|
        dir = test_dir / entry
        next unless real_directory?(dir)
        if source = first_source(dir)
          raise UserError.new("#{source} is in a subdirectory of test/; a test package's sources go directly in test/")
        end
      end
      if manifest.dependency?(name)
        raise UserError.new("the key `#{name}` is the library's own name, which the test package imports it by; rename the key")
      end
      manifest.test_deps.each do |dep|
        next if manifest.deps.any? { |d| d.key == dep.key }
        if found = importer(source_dir, dep.key)
          raise UserError.new("#{found} imports `#{dep.key}`, which is in `test-deps`; only the test package may import it")
        end
      end
    end

    # Each line of the `.zn` files directly in *dir* that imports *key*, in
    # any of the import forms (spec packages.md §3.3), as a path from the
    # root and a line number.
    def importers(dir : Path, key : String) : Array({String, Int32})
      import = /^\s*import\s+#{Regex.escape(key)}(?![A-Za-z0-9_])/
      found = [] of {String, Int32}
      return found unless Dir.exists?(dir)
      Dir.children(dir).sort!.each do |name|
        path = dir / name
        next unless name.ends_with?(".zn") && File.file?(path)
        File.read_lines(path).each_with_index(1) do |line, number|
          found << {path.relative_to(root).to_posix.to_s, number} if import.matches?(line)
        end
      end
      found
    end

    private def importer(dir : Path, key : String) : String?
      importers(dir, key).first?.try { |file, line| "#{file}:#{line}" }
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
