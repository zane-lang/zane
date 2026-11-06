require "../self_update"
require "../progress"

module Zane::Commands
  # `zane self update [tag]` (§4.2).
  class SelfCommand
    USAGE = "usage: zane self update [vMAJOR.MINOR[.PATCH]]"

    def initialize(@args : Array(String), @output : IO, @error : IO)
    end

    def run : Int32
      raise UserError.new(USAGE) unless @args.first? == "update" && @args.size <= 2
      result = Progress.run(@error) { |progress| SelfUpdate.run(@args[1]?, progress: progress) }
      self.class.describe(result, @output)
      0
    end

    # Says on *output* what the update did.
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
