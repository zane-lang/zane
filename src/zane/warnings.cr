module Zane
  # The compiler's error stream for a command's several compiler runs, which
  # passes everything on but a warning already shown: a C file of a library
  # package warns again in each build that compiles it.
  class Warnings < IO
    @line = IO::Memory.new
    @block : Array(String)? = nil
    @shown = Set(String).new

    def initialize(@io : IO)
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("Warnings is write-only")
    end

    def write(slice : Bytes) : Nil
      slice.each do |byte|
        @line.write_byte(byte)
        line if byte == '\n'.ord
      end
    end

    # Writes a partial line and an unfinished block as they stand.
    def flush : Nil
      @block.try { |b| b.each { |l| @io << l } }
      @block = nil
      @io << @line.to_s
      @line.clear
      @io.flush
    end

    # A diagnostic is a block from its `File "` line to its `Warning:` or
    # `Error:` line; a warning block shown before is dropped. A block that
    # another `File "` line starts before it ends is passed on as it is.
    private def line : Nil
      text = @line.to_s
      @line.clear
      if (block = @block) && text.starts_with?("File \"")
        block.each { |l| @io << l }
        @block = [text]
      elsif block = @block
        block << text
        if text.starts_with?("Warning: ")
          whole = block.join
          @io << whole if @shown.add?(whole)
          @block = nil
        elsif text.starts_with?("Error: ")
          block.each { |l| @io << l }
          @block = nil
        end
      elsif text.starts_with?("File \"")
        @block = [text]
      else
        @io << text
      end
    end
  end
end
