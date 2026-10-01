module Zane
  # Where `zane` keeps what it shares between projects: `~/.zane`, or the
  # directory `ZANE_HOME` names.
  module Home
    def self.dir : Path
      if home = ENV["ZANE_HOME"]?.presence
        Path[home].expand
      else
        Path.home / ".zane"
      end
    end

    # The installed compilers, one directory per release tag.
    def self.toolchains : Path
      dir / "toolchains"
    end
  end
end
