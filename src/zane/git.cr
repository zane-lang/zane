require "file_utils"
require "./errors"

module Zane
  # What `zane` asks of git: a repository's tags, and a checkout of one
  # commit. Only git's own commands are used, so any host git can reach works,
  # and no API is needed.
  module Git
    # The tags of the repository at *url*, each with the commit it points to.
    def self.tags(url : String) : Hash(String, String)
      output = IO::Memory.new
      error = IO::Memory.new
      status = run(["ls-remote", "--tags", url], output, error)
      unless status.success?
        raise UserError.new("cannot list the tags of #{url}:\n#{error.to_s.strip}")
      end
      parse_tags(output.to_s)
    end

    # The tags in `git ls-remote --tags` output. An annotated tag is listed
    # twice, and its peeled `^{}` line names the commit.
    def self.parse_tags(ls_remote : String) : Hash(String, String)
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
      tags
    end

    # The commit *tag* points to now in the repository at *url*.
    def self.resolve(url : String, tag : String) : String
      tags(url)[tag]? || raise UserError.new("#{url} has no tag #{tag}")
    end

    # Checks out the repository at *url* as it is at *tag* into *dir*, which
    # must not exist, and refuses it unless that is *commit* (spec
    # dependencies.md §4). Nothing is left at *dir* unless it succeeds.
    def self.checkout(url : String, tag : String, commit : String, dir : Path) : Nil
      Dir.mkdir_p(dir.parent)
      partial = dir.parent / ".#{dir.basename}.#{Random::Secure.hex(4)}"
      error = IO::Memory.new
      args = ["-c", "advice.detachedHead=false", "clone", "--quiet", "--depth", "1",
              "--branch", tag, url, partial.to_s]
      unless run(args, Process::Redirect::Close, error).success?
        raise UserError.new("cannot fetch #{url} at #{tag}:\n#{error.to_s.strip}")
      end
      head = head(partial)
      unless head.starts_with?(commit) || commit.starts_with?(head)
        raise UserError.new("security error: #{url} tag #{tag} is commit #{head}, but the lock file pins #{commit}. " \
                            "The tag has moved; if that is intended, update the pin with `zane update`")
      end
      File.rename(partial, dir)
    ensure
      FileUtils.rm_rf(partial) if partial && Dir.exists?(partial)
    end

    # The commit checked out in *dir*.
    def self.head(dir : Path) : String
      output = IO::Memory.new
      unless run(["-C", dir.to_s, "rev-parse", "HEAD"], output, Process::Redirect::Close).success?
        raise UserError.new("#{dir} is not a git checkout")
      end
      output.to_s.strip
    end

    private def self.run(args : Array(String), output, error) : Process::Status
      Process.run("git", args, output: output, error: error)
    rescue File::NotFoundError
      raise UserError.new("git is not installed; zane needs it to fetch packages")
    end
  end
end
