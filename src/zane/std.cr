require "./cache"
require "./errors"
require "./git"
require "./home"
require "./package_url"
require "./progress"

module Zane
  # The `std` project, which holds `core`. `zane init` makes new projects
  # depend on it, and the installers and `zane self update` keep its newest
  # release in the package cache, so `init` works offline
  # (docs/design/cli.md §2.1, §4.2).
  module Std
    URL = "https://github.com/zane-lang/std"

    # The key a project depends on it by.
    KEY = "std"

    # Where the latest std came from: listed online and now in the cache, or
    # found in the cache because the repository could not be reached.
    record Pin, tag : String, commit : String, cached : Bool

    # Lists the tags of *url*, and puts the checkout of its newest version tag
    # in the package cache unless it is there already.
    def self.fetch(url : String = URL, packages : Path = Home.packages) : Pin
      package = PackageUrl.parse(url)
      progress = Progress.current
      progress.step("Finding the newest std release")
      tag, commit = begin
        tags = Git.tags(url)
        newest = Git.newest_version(tags) || raise UserError.new("#{url} has no version tags")
        {newest, tags[newest]}
      rescue error
        progress.fail
        raise error
      end
      progress.done("Found std #{tag} (commit #{commit[0, 12]})")
      CacheEntry.new(package, tag, packages).source(commit)
      Pin.new(tag, commit, false)
    end

    # The newest version of *url* whose checkout is in the package cache, or
    # nil when there is none.
    def self.cached(url : String = URL, packages : Path = Home.packages) : Pin?
      dir = packages.join(PackageUrl.parse(url).normalized.split('/'))
      return nil unless Dir.exists?(dir)
      checkouts = Dir.children(dir).select { |tag| Dir.exists?(dir / tag / "src") && !PackageUrl.tag_error(tag) }
      tag = Git.newest_version(checkouts.to_h { |t| {t, ""} }) || return nil
      Pin.new(tag, Git.head(dir / tag / "src"), true)
    rescue UserError
      nil
    end

    # The newest std: fetched when *url* can be reached, and otherwise the
    # newest version already in the package cache.
    def self.pin(url : String = URL, packages : Path = Home.packages) : Pin
      fetch(url, packages)
    rescue error : UserError
      if found = cached(url, packages)
        Progress.current.note("Cannot reach std; using std #{found.tag} from the package cache")
        return found
      end
      raise UserError.new("#{error.message}\nNo std release is in the package cache either. " \
                          "Run `zane self install-std` once online, or run again with --no-std")
    end
  end
end
