module Zane
  # A transient status line for interactive toolchain installations. Keep it
  # off stdout, and leave redirected output and dumb terminals untouched.
  class InstallProgress
    FRAMES = {'|', '/', '-', '\\'}

    @message = ""
    @frame = 0
    @worker : Fiber::ExecutionContext::Isolated?
    @updates = Channel(String).new

    def initialize(@output : IO)
      @enabled = @output.tty? && ENV["TERM"]? != "dumb"
    end

    def self.run(output : IO, &block : InstallProgress -> T) : T forall T
      progress = new(output)
      yield progress
    ensure
      progress.try &.finish
    end

    def stage(message : String) : Nil
      return unless @enabled
      # A separate thread keeps animating during CPU-bound checksum and
      # extraction work too. Only that thread writes to the output stream.
      @worker ||= Fiber::ExecutionContext::Isolated.new("toolchain progress") do
        begin
          loop do
            select
            when update = @updates.receive?
              break unless update
              @message = update
              render
            when timeout(100.milliseconds)
              render unless @message.empty?
            end
          end
        ensure
          @updates.close
          @output << "\r\e[K"
          @output.flush
        end
      end
      @updates.send(message)
    end

    def finish : Nil
      return unless worker = @worker
      @updates.close
      worker.wait
      @worker = nil
    end

    private def render : Nil
      @output << '\r' << FRAMES[@frame % FRAMES.size] << ' ' << @message << "\e[K"
      @output.flush
      @frame += 1
    end
  end
end
