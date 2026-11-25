require "../self_update"
require "../progress"
require "../home"
require "../std"

module Zane::Commands
  # `zane self update [tag]` and `zane self install-std` (§4.2).
  class SelfCommand
    USAGE = "usage: zane self update [vMAJOR.MINOR[.PATCH]] | install-std"

    # *std_url* is where `std` is and *packages* the package cache; tests
    # change both.
    def initialize(@args : Array(String), @output : IO, @error : IO,
                   @std_url : String = Std::URL, @packages : Path = Home.packages)
    end

    def run : Int32
      case
      when @args == ["install-std"]
        pin = Progress.run(@error) { Std.fetch(@std_url, @packages) }
        @output.puts "std #{pin.tag} is in the package cache, for `zane init`."
      when @args.first? == "update" && @args.size <= 2
        result = Progress.run(@error) { |progress| SelfUpdate.run(@args[1]?, progress: progress) }
        self.class.describe(result, @output)
        install_std
      else
        raise UserError.new(USAGE)
      end
      0
    end

    # Puts the newest std in the package cache after an update. The update
    # has succeeded whether or not this does, so a failure is only warned of.
    private def install_std : Nil
      pin = Progress.run(@error) { Std.fetch(@std_url, @packages) }
      @output.puts "std #{pin.tag} is in the package cache, for `zane init`."
    rescue error : UserError | File::Error | IO::Error
      @error.puts "zane: warning: cannot put the newest std in the package cache: #{error.message}"
      if found = Std.cached(@std_url, @packages)
        @error.puts "`zane init` uses std #{found.tag}, already there, offline; `zane self install-std` tries again."
      else
        @error.puts "No std is in the package cache, so `zane init` needs to reach std, or --no-std; " \
                    "`zane self install-std` tries again."
      end
    end

    # Prints on *output* the result of the update.
    def self.describe(result : SelfUpdate::Result, output : IO) : Nil
      path = result.path
      case result.outcome
      in .installed?
        output.puts "Updated zane #{SelfUpdate.current} -> #{result.tag} at #{path}."
      in .current?
        output.puts "zane #{result.tag} is already installed at #{path}; nothing changed."
      in .newer?
        output.puts "This zane, #{SelfUpdate.current}, is newer than the latest release, #{result.tag}; " \
                    "nothing changed. Run `zane self update #{result.tag}` to install it anyway."
      end
    end
  end
end
