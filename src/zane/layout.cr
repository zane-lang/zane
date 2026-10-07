require "./errors"
require "./project"

module Zane
  # A project's packages as its directories lay them out: library packages
  # in `lib/`, each with its subpackages, program packages in `bin/`, and
  # test packages in `test/` (spec packages.md §2). The compiler reads one
  # directory per package, so `zane` is the one that sees the layout and
  # holds it to its rules.
  class Layout
    # A library package: its path within `lib/`, its directory names joined
    # by `.` (`gui.opengl` for a subpackage), and its directory.
    record Lib, path : String, dir : Path do
      # The name its files declare: the last part of its path (§2.2).
      def name : String
        path.split('.').last
      end

      def top? : Bool
        !path.includes?('.')
      end

      # The path of the package whose directory holds this one's.
      def parent : String?
        i = path.rindex('.')
        i ? path[0, i] : nil
      end

      # The top-level library package it lies within, or itself.
      def top : String
        path.split('.').first
      end

      # Whether another project may import it (§4.3).
      def public? : Bool
        top? && !name.starts_with?('_')
      end
    end

    # A program package: the directory in `bin/` that names it.
    record Program, name : String, dir : Path

    # A test package: its path under `test/`, joined by `.` like a library
    # package's, and its directory. A nested one tests the subpackage of the
    # same path (§7.1).
    record Test, path : String, dir : Path do
      def nested? : Bool
        path.includes?('.')
      end

      # How a person names it, as `zane test gui/opengl` does.
      def label : String
        path.tr(".", "/")
      end
    end

    getter root : Path
    getter libs = [] of Lib
    getter programs = [] of Program
    getter tests = [] of Test

    def initialize(@root : Path)
      read_libs
      read_programs
      read_tests
      check_names
      if @libs.empty? && @programs.empty?
        raise UserError.new("#{@root} has no packages: a library package is a directory of lib/, and a program a directory of bin/")
      end
    end

    def lib?(path : String) : Lib?
      @libs.find { |l| l.path == path }
    end

    def top_libs : Array(Lib)
      @libs.select(&.top?)
    end

    # The packages another project may import (§4.3).
    def public_libs : Array(Lib)
      @libs.select(&.public?)
    end

    # The library packages of the project that *lib* may import, each by the
    # key it imports it by, its name (packages.md §4.3): a top-level package
    # imports the other top-level ones and its own subpackages, and a
    # subpackage its own subpackages and every top-level package but the
    # one it lies within.
    def keys(library : Lib) : Array({String, Lib})
      children = @libs.select { |l| l.parent == library.path }
      tops = top_libs.reject { |l| l.path == library.top }
      (tops + children).map { |l| {l.name, l} }
    end

    # What a program package imports of its own project: every top-level
    # library package.
    def program_keys : Array({String, Lib})
      top_libs.map { |l| {l.name, l} }
    end

    # What a test package imports of its own project: every top-level
    # library package and, for a nested one, the subpackage it tests (§7.3).
    def test_keys(test : Test) : Array({String, Lib})
      keys = program_keys
      if test.nested?
        library = lib?(test.path).not_nil!
        keys << {library.name, library}
      end
      keys
    end

    private def read_libs : Nil
      dir = @root / "lib"
      return unless Dir.exists?(dir)
      no_sources(dir)
      children(dir).each do |entry|
        if entry.starts_with?('_') ? Project.valid_name?(entry[1..]) : Project.valid_name?(entry)
          package = Lib.new(entry, dir / entry)
          sources!(package.dir, "the library package #{entry}")
          @libs << package
          read_subpackages(package)
        else
          raise UserError.new("lib/#{entry}/ is not a package name: a library package is named in camelCase, like `math`, after a `_` when it is private to the project")
        end
      end
    end

    private def read_subpackages(parent : Lib) : Nil
      children(parent.dir).each do |entry|
        dir = parent.dir / entry
        shown = "lib/#{parent.path.tr(".", "/")}/#{entry}/"
        if sources?(dir)
          unless Project.valid_name?(entry)
            raise UserError.new("#{shown} is not a subpackage name: it is named in camelCase, like `opengl`, and only a top-level library package's name may start with `_`")
          end
          package = Lib.new("#{parent.path}.#{entry}", dir)
          @libs << package
          read_subpackages(package)
        elsif source = first_source(dir)
          raise UserError.new("#{source} has no package above it: #{shown} holds no .zn files, so it is no subpackage that could hold one")
        end
      end
    end

    private def read_programs : Nil
      dir = @root / "bin"
      return unless Dir.exists?(dir)
      no_sources(dir)
      children(dir).each do |entry|
        unless Project.valid_name?(entry)
          raise UserError.new("bin/#{entry}/ is not a program name: it is named in camelCase, like `viewer`")
        end
        program = Program.new(entry, dir / entry)
        sources!(program.dir, "the program #{entry}")
        children(program.dir).each do |sub|
          if source = first_source(program.dir / sub)
            raise UserError.new("#{source} is in a subdirectory of bin/#{entry}/; a program package's files go directly in it, and its parts in lib/")
          end
        end
        @programs << program
      end
    end

    private def read_tests : Nil
      dir = @root / Project::TEST_PACKAGE
      return unless Dir.exists?(dir)
      no_sources(dir)
      children(dir).each { |entry| read_test(dir / entry, entry) }
    end

    private def read_test(dir : Path, path : String) : Nil
      if sources?(dir)
        test = Test.new(path, dir)
        if test.nested? && !lib?(path)
          raise UserError.new("test/#{test.label}/ tests no subpackage: lib/#{test.label}/ is not one, and a nested test package mirrors one")
        end
        @tests << test
      end
      children(dir).each { |entry| read_test(dir / entry, "#{path}.#{entry}") }
    end

    # The names one project keeps apart (§2.2).
    private def check_names : Nil
      tops = top_libs.map(&.name)
      if tops.includes?(Project::TEST_PACKAGE)
        raise UserError.new("lib/test/ cannot be a library package: `test` is the name every test package declares")
      end
      @programs.each do |p|
        if tops.includes?(p.name)
          raise UserError.new("bin/#{p.name}/ has the name of the library package lib/#{p.name}/; a program's name differs from every top-level library package's")
        end
      end
      @libs.reject(&.top?).each do |l|
        if tops.includes?(l.name)
          raise UserError.new("lib/#{l.path.tr(".", "/")}/ has the name of the library package lib/#{l.name}/; a subpackage's name differs from every top-level library package's")
        end
      end
    end

    # The directories in *dir*, sorted, without following a symbolic link.
    private def children(dir : Path) : Array(String)
      Dir.children(dir).select { |e| real_directory?(dir / e) }.sort!
    end

    private def sources?(dir : Path) : Bool
      Dir.children(dir).any? { |e| e.ends_with?(".zn") && File.file?(dir / e) }
    end

    private def sources!(dir : Path, what : String) : Nil
      return if sources?(dir)
      raise UserError.new("#{dir} holds no .zn files, so #{what} has no sources")
    end

    private def no_sources(dir : Path) : Nil
      Dir.children(dir).sort.each do |e|
        if e.ends_with?(".zn") && File.file?(dir / e)
          raise UserError.new("#{dir / e} is directly in #{dir.basename}/; each package is a directory of its own there")
        end
      end
    end

    private def first_source(dir : Path) : Path?
      Dir.children(dir).sort.each do |entry|
        path = dir / entry
        return path if entry.ends_with?(".zn") && File.file?(path)
        if real_directory?(path) && (found = first_source(path))
          return found
        end
      end
      nil
    end

    private def real_directory?(path : Path) : Bool
      File.info?(path, follow_symlinks: false).try(&.directory?) || false
    end
  end
end
