# src/pty/filter.cr
module PTY
  abstract class Filter
    abstract def call(chunk : Bytes) : Bytes

    def finish : Bytes
      Bytes.empty
    end
  end

  class TapFilter < Filter
    def initialize(&@block : Bytes ->)
    end

    def call(chunk : Bytes) : Bytes
      @block.call(chunk)
      chunk
    end
  end

  class LineFilter < Filter
    @buffer = IO::Memory.new
    @block : (Bytes -> Bytes)?

    def initialize(&@block : Bytes -> Bytes)
    end

    def initialize
      @block = nil
    end

    def on_line(line : Bytes) : Bytes
      if block = @block
        block.call(line)
      else
        line
      end
    end

    def call(chunk : Bytes) : Bytes
      @buffer.write(chunk)
      data = @buffer.to_slice

      start  = 0
      output = IO::Memory.new
      while (index = data[start..].index('\n'.ord.to_u8))
        stop    = start + index
        emitted = on_line(data[start...stop])
        output.write(emitted)
        output.write_byte('\n'.ord.to_u8) unless emitted.empty?
        start = stop + 1
      end

      rest = data[start..]
      @buffer.clear
      @buffer.write(rest)

      output.to_slice
    end

    def finish : Bytes
      rest = @buffer.to_slice
      @buffer.clear
      return Bytes.empty if rest.empty?
      on_line(rest)
    end
  end
end
