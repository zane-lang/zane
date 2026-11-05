module Zane
  {% if flag?(:linux) || flag?(:darwin) %}
    # The terminal's size, so the line being redrawn never wraps.
    lib LibTerminal
      struct Winsize
        rows : UInt16
        columns : UInt16
        x_pixels : UInt16
        y_pixels : UInt16
      end

      fun ioctl(fd : LibC::Int, request : LibC::ULong, ...) : LibC::Int
    end
  {% end %}

  # A step-by-step account of an interactive toolchain installation. Every
  # finished step stays on screen with a check mark and how long it took; the
  # step under way is redrawn in place with a spinner and, when it moves a
  # known number of bytes, a progress bar, the amount done, the rate and the
  # time left. It writes only to *output*, never to stdout, and leaves
  # redirected output and dumb terminals untouched.
  class InstallProgress
    {% if flag?(:win32) %}
      FRAMES = {'|', '/', '-', '\\'}
      DONE   = "+"
      FAILED = "x"
      FULL   = '#'
      EMPTY  = '-'
    {% else %}
      FRAMES = {'⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'}
      DONE   = "✓"
      FAILED = "✗"
      FULL   = '█'
      EMPTY  = '░'
    {% end %}
    BAR     = 24
    MIN_BAR = 10
    # How far back the rate shown for a running step looks.
    RATE_WINDOW = 2.seconds

    # How much of a step's work is done, in bytes. The drawing thread calls it.
    alias Meter = -> Int64

    private record Begin, label : String, at : Time::Instant, total : Int64?, meter : Meter?
    private record Finish, summary : String?, at : Time::Instant, bytes : Bool
    private record Fail
    private alias Message = Begin | Finish | Fail

    @worker : Fiber::ExecutionContext::Isolated?
    @updates = Channel(Message).new
    @active = false

    # The drawing thread's state.
    @step : Begin?
    @frame = 0
    @samples = Deque({Time::Instant, Int64}).new
    # The bar only ever narrows during a step, so it does not jitter.
    @bar = BAR

    def initialize(@output : IO)
      @enabled = @output.tty? && ENV["TERM"]? != "dumb"
      @color = ENV["NO_COLOR"]?.presence.nil?
    end

    # Yields a display for *output*. The step still running when the block
    # returns is marked done, and the one it raised in is marked failed.
    def self.run(output : IO, & : InstallProgress -> T) : T forall T
      progress = new(output)
      begin
        result = yield progress
      rescue error
        progress.finish(false)
        raise error
      end
      progress.finish(true)
      result
    end

    # Starts the step *label*, marking the one before it done. A *total* and
    # a *meter* draw a progress bar; a meter alone shows the bytes and rate.
    def step(label : String, total : Int64? = nil, &meter : -> Int64) : Nil
      begin_step(label, total, meter)
    end

    def step(label : String) : Nil
      begin_step(label, nil, nil)
    end

    # Marks the running step done, as *summary* when given. A metered step
    # adds the bytes it moved and its rate unless *bytes* is false.
    def done(summary : String? = nil, bytes : Bool = true) : Nil
      return unless @enabled && @active
      @active = false
      @updates.send(Finish.new(summary, Time.instant, bytes))
    end

    def finish(success : Bool) : Nil
      return unless worker = @worker
      success ? done : (@updates.send(Fail.new) if @active)
      @active = false
      @updates.close
      worker.wait
      @worker = nil
    end

    private def begin_step(label : String, total : Int64?, meter : Meter?) : Nil
      return unless @enabled
      done
      # A separate thread keeps animating during CPU-bound checksum and
      # extraction work too. Only that thread writes to the output stream.
      @worker ||= Fiber::ExecutionContext::Isolated.new("toolchain progress") do
        begin
          loop do
            select
            when update = @updates.receive?
              break unless update
              receive(update)
            when timeout(100.milliseconds)
              render
            end
          end
        ensure
          @updates.close
          @output << "\r\e[K"
          @output.flush
        end
      end
      @active = true
      @updates.send(Begin.new(label, Time.instant, total, meter))
    end

    private def receive(message : Message) : Nil
      case message
      in Begin
        @step = message
        @samples.clear
        @bar = BAR
        render
      in Finish
        if step = @step
          @output << "\r\e[K" << paint(DONE, 32) << ' ' << (message.summary || step.label)
          @output << ' ' << paint("(#{summary(step, message)})", 2) << '\n'
          @output.flush
        end
        @step = nil
      in Fail
        if step = @step
          @output << "\r\e[K" << paint(FAILED, 31) << ' ' << step.label << '\n'
          @output.flush
        end
        @step = nil
      end
    end

    private def summary(step : Begin, finish : Finish) : String
      elapsed = finish.at - step.at
      meter = step.meter
      return duration(elapsed) unless meter && finish.bytes
      moved = meter.call
      seconds = elapsed.total_seconds
      text = "#{bytes(moved)} in #{duration(elapsed)}"
      seconds >= 0.05 ? "#{text}, #{bytes((moved / seconds).to_i64)}/s" : text
    end

    private def render : Nil
      return unless step = @step
      spinner = paint(FRAMES[@frame % FRAMES.size].to_s, 36)
      @frame += 1
      @output << '\r' << spinner << ' ' << fit(step, columns - 3) << "\e[K"
      @output.flush
    end

    # The running step's line, dropping its least useful details until it
    # fits in *width* characters, and cutting the label short if it still
    # does not.
    private def fit(step : Begin, width : Int32) : String
      fraction = percent = amount = speed = left = nil
      if meter = step.meter
        done = meter.call
        now = Time.instant
        @samples << {now, done}
        while @samples.size > 2 && now - @samples.first[0] > RATE_WINDOW
          @samples.shift
        end
        first_at, first_done = @samples.first
        window = (now - first_at).total_seconds
        rate = window >= 0.3 ? (done - first_done) / window : 0.0
        total = step.total
        if total && total > 0
          fraction = (done / total).clamp(0.0, 1.0)
          percent = "#{(fraction * 100).floor.to_i}%"
          amount = amounts(done, total)
          left = "#{duration(((total - done) / rate).seconds)} left" if rate > 0 && total > done
        else
          amount = bytes(done)
        end
        speed = "#{bytes(rate.to_i64)}/s" if rate > 0
      end
      # The bar narrows before anything is left out. Then the time left goes
      # first, the rate, the bar, and the amounts.
      layouts = {[percent, amount, speed, left], [percent, amount, speed], [percent, amount], [percent], [] of String?}
      {true, false}.each do |with_bar|
        next if with_bar && !fraction
        layouts.each do |details|
          # A bar is no use without the percentage beside it.
          next if with_bar && details.empty?
          text = ([step.label] + details.compact).join("  ")
          next if text.size > width
          return text unless with_bar && fraction
          room = {width - text.size - 2, @bar}.min
          next if room < MIN_BAR
          @bar = room
          filled = (fraction * room).floor.to_i
          bar = "#{FULL.to_s * filled}#{EMPTY.to_s * (room - filled)}"
          return ([step.label, bar] + details.compact).join("  ")
        end
      end
      step.label.size <= width ? step.label : "#{step.label[0, {width - 1, 0}.max]}…"
    end

    # "12.5 / 80.0 MB", or "512 KB / 1.2 MB" when the units differ.
    private def amounts(done : Int64, total : Int64) : String
      done_text, total_text = bytes(done), bytes(total)
      unit = total_text.split(' ').last
      done_text.ends_with?(" #{unit}") ? "#{done_text.rchop(" #{unit}")} / #{total_text}" : "#{done_text} / #{total_text}"
    end

    private def paint(text : String, code : Int32) : String
      @color ? "\e[#{code}m#{text}\e[0m" : text
    end

    private def columns : Int32
      if (env = ENV["COLUMNS"]?.try(&.to_i?)) && env > 0
        return env
      end
      {% if flag?(:linux) || flag?(:darwin) %}
        if (output = @output).is_a?(IO::FileDescriptor)
          size = LibTerminal::Winsize.new
          request = {{ flag?(:darwin) ? 0x40087468 : 0x5413 }}
          if LibTerminal.ioctl(output.fd, LibC::ULong.new(request), pointerof(size)) == 0 && size.columns > 0
            return size.columns.to_i
          end
        end
      {% end %}
      80
    end

    private def bytes(count : Int64) : String
      return "#{count} B" if count < 1000
      value = count.to_f
      unit = "B"
      {"KB", "MB", "GB", "TB"}.each do |next_unit|
        break if value < 1000
        value /= 1000
        unit = next_unit
      end
      "#{value.round(1)} #{unit}"
    end

    private def duration(span : Time::Span) : String
      seconds = span.total_seconds
      return "#{seconds.round(1)}s" if seconds < 60
      whole = seconds.round.to_i
      "#{whole // 60}m #{(whole % 60).to_s.rjust(2, '0')}s"
    end
  end
end
