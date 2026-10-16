# An in-memory terminal, so interactive output can be checked on every host.
class SpecTerminal < IO::Memory
  @flushes = Atomic(Int32).new(0)

  def flushes : Int32
    @flushes.get
  end

  def tty? : Bool
    true
  end

  def flush : Nil
    @flushes.add(1)
  end
end

def with_terminal(&)
  term = ENV["TERM"]?
  ENV["TERM"] = "xterm"
  yield SpecTerminal.new
ensure
  term ? (ENV["TERM"] = term) : ENV.delete("TERM")
end
