require "./errors"

module Zane
  # A compiler release: the tag a project's `zane-version` names and the commit
  # its lock row pins (spec dependencies.md §14).
  record CompilerRelease, tag : String, commit : String do
    # Where compiler releases are tagged. It is also the `url` of the reserved
    # `zane` lock row.
    URL = "https://github.com/zane-lang/compiler"

    # A compiler tag: `vMAJOR.MINOR`.
    TAG = /\Av(\d+)\.(\d+)\z/

    # The release *tag* of the repository at *url*, or the newest one when *tag*
    # is nil. Asks git, so it needs no API access.
    def self.resolve(tag : String? = nil, url : String = URL) : CompilerRelease
      output = IO::Memory.new
      error = IO::Memory.new
      status = begin
        Process.run("git", ["ls-remote", "--tags", url], output: output, error: error)
      rescue File::NotFoundError
        raise UserError.new("git is not installed; zane needs it to find compiler releases")
      end
      unless status.success?
        raise UserError.new("cannot list the compiler releases at #{url}:\n#{error.to_s.strip}")
      end
      pick(parse(output.to_s), tag, url)
    end

    # The release tags in `git ls-remote --tags` output, each with the commit
    # it points to. An annotated tag is listed twice, and its peeled `^{}` line
    # names the commit.
    def self.parse(ls_remote : String) : Hash(String, String)
      tags = {} of String => String
      ls_remote.each_line do |line|
        commit, ref = line.split('\t', 2)
        next unless ref && ref.starts_with?("refs/tags/")
        name = ref.lchop("refs/tags/")
        if name.ends_with?("^{}")
          tags[name.rchop("^{}")] = commit
        else
          tags[name] ||= commit
        end
      end
      tags.select { |name, _| TAG.matches?(name) }
    end

    private def self.pick(tags : Hash(String, String), tag : String?, url : String) : CompilerRelease
      if tag
        commit = tags[tag]? || raise UserError.new(
          "#{url} has no release #{tag}" + (tags.empty? ? "" : "; its releases are #{sorted(tags).join(", ")}"))
        return new(tag, commit)
      end
      newest = sorted(tags).last? || raise UserError.new(
        "#{url} has no release yet, so there is no compiler to pin")
      new(newest, tags[newest])
    end

    private def self.sorted(tags : Hash(String, String)) : Array(String)
      tags.keys.sort_by do |name|
        m = TAG.match(name).not_nil!
        {m[1].to_i, m[2].to_i}
      end
    end
  end
end
