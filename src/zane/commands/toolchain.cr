require "../toolchain"

module Zane::Commands
  class Toolchain
    USAGE = "usage: zane toolchain install [vMAJOR.MINOR]"

    def initialize(@args : Array(String), @output : IO, @error : IO)
    end

    def run : Int32
      unless @args.first? == "install" && @args.size <= 2
        raise UserError.new(USAGE)
      end
      release = Zane::Toolchain.install(@args[1]?)
      @output.puts "Zane toolchain #{release.tag} is installed in #{Home.toolchains / release.tag}."
      0
    end
  end
end
