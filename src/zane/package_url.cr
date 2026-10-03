require "./errors"
require "./sha256"

module Zane
  # A package's URL, which is its identity, and what derives from it: the
  # directory the package cache keeps it in, and the identity hash its symbols
  # carry (spec dependencies.md §6.1, §7).
  struct PackageUrl
    # What a cache directory name, and a version tag, may hold. Anything else
    # is refused rather than escaped (§7). It is also what the compiler accepts
    # in a stamp's tag.
    SAFE = /\A[A-Za-z0-9._+~-]+\z/

    # The URL as written, which is what git is given.
    getter url : String

    # The URL's host and path, with the scheme, any SSH user and an SCP-style
    # `:` taken away, so every spelling of one repository gives the same one.
    getter normalized : String

    def initialize(@url : String, @normalized : String)
    end

    def self.parse(url : String) : PackageUrl
      rest = url
      if scheme = rest.match(/\A[A-Za-z][A-Za-z0-9+.-]*:\/\//)
        rest = rest[scheme[0].size..]
        rest = rest.sub(/\A[^\/@]*@/, "")
      elsif scp = rest.match(/\A(?:[^\/@:]+@)?([^\/:]+):(.*)\z/)
        rest = "#{scp[1]}/#{scp[2]}"
      end
      normalized = rest.strip('/')
      components = normalized.split('/')
      if normalized.empty? || components.any? { |c| !safe?(c) }
        raise UserError.new("`#{url}` is not a package URL: its host and path are directory names, " \
                            "made of letters, digits and `._+~-`")
      end
      new(url, normalized)
    end

    # Whether *component* may name a directory as it is.
    def self.safe?(component : String) : Bool
      SAFE.matches?(component) && component != "." && component != ".."
    end

    # Why the version *tag* cannot name a cache directory and begin a stamp,
    # or nil when it can.
    def self.tag_error(tag : String) : String?
      return nil if safe?(tag) && !tag.includes?('~')
      "`#{tag}` is not a version tag zane can use: a tag is made of letters, digits and `._+-`"
    end

    # The first 16 hex digits of the SHA-256 of the normalized URL.
    def identity_hash : String
      SHA256.hexdigest(@normalized)[0, 16]
    end

    # What replaces the `!` placeholder in the symbols of the package's
    # version *tag*.
    def stamp(tag : String) : String
      "#{tag}%#{identity_hash}%"
    end

    # The last part of the path, which `zane add` takes as the key.
    def basename : String
      @normalized.split('/').last.rchop(".git")
    end

    def to_s(io : IO) : Nil
      io << @url
    end
  end
end
