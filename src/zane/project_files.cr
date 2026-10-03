require "./coda"
require "./errors"
require "./manifest"

module Zane
  # Changes a project's `zane.coda` and `zane-lock.coda`, which only the
  # dependency commands write, and always together (spec dependencies.md
  # §2.3).
  module ProjectFiles
    # How the files `zane` writes are indented, as `zane init` writes them.
    INDENT = "    "

    # Edits the manifest in *root* with *manifest* and, when given, the lock
    # file with *lock*. Each file is written beside itself and renamed into
    # place, so neither is left half-written. The manifest is kept until the
    # lock is in place, and put back if the lock cannot be, so the two files
    # never disagree.
    def self.change(root : Path, manifest : Coda::Doc -> Nil, lock : (Coda::Doc -> Nil)? = nil) : Nil
      edited = edit(root / Manifest::FILE, manifest)
      locked = lock.try { |l| edit(root / Manifest::LOCK, l) }
      unless locked
        File.rename(edited, root / Manifest::FILE)
        return
      end
      backup = root / ".#{Manifest::FILE}.#{Random::Secure.hex(4)}"
      File.copy(root / Manifest::FILE, backup)
      File.rename(edited, root / Manifest::FILE)
      begin
        File.rename(locked, root / Manifest::LOCK)
      rescue error : File::Error
        File.rename(backup, root / Manifest::FILE)
        raise UserError.new("cannot write #{root / Manifest::LOCK}: #{error.message}; nothing was changed")
      end
    ensure
      File.delete?(edited) if edited
      File.delete?(locked) if locked
      File.delete?(backup) if backup
    end

    # The `deps` table of *doc*, made when it has none.
    def self.deps(doc : Coda::Doc) : Coda::KeyedTable
      doc.root["deps"] = Coda::KeyedTable.new(["version", "from"]) unless doc.root.has_key?("deps")
      doc.root["deps"].as_keyed_table
    end

    def self.resolutions(doc : Coda::Doc) : Coda::KeyedTable
      doc.root["resolutions"].as_keyed_table
    end

    private def self.edit(path : Path, change : Coda::Doc -> Nil) : Path
      partial = path.parent / ".#{path.basename}.#{Random::Secure.hex(4)}"
      Coda::Doc.parse_file(path) do |doc|
        change.call(doc)
        File.write(partial, doc.serialize(INDENT))
      end
      partial
    rescue error : Coda::Error
      raise UserError.new("#{path}: #{error.message}")
    end
  end
end
