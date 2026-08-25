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

  module UTF8
    class Filter < ::PTY::Filter
      @incomplete : Bytes = Bytes.empty

      def call(chunk : Bytes) : Bytes
        return Bytes.empty if chunk.empty? && @incomplete.empty?

        if @incomplete.empty?
          data = chunk
        else
          data = Bytes.new(@incomplete.size + chunk.size)
          @incomplete.copy_to(data[0, @incomplete.size])
          chunk.copy_to(data[@incomplete.size, chunk.size])
          @incomplete = Bytes.empty
        end

        split_idx = data.size
        i         = 1

        while i <= 4 && i <= data.size
          byte = data[data.size - i]

          if byte < 0x80_u8
            break
          elsif byte >= 0xC0_u8
            expected = if byte >= 0xF0_u8
                         4
                       elsif byte >= 0xE0_u8
                         3
                       else
                         2
                       end

            split_idx = data.size - i if expected > i
            break
          end

          i += 1
        end

        if split_idx < data.size
          tail_size   = data.size - split_idx
          @incomplete = Bytes.new(tail_size)
          data[split_idx, tail_size].copy_to(@incomplete)
        end

        data[0, split_idx]
      end

      def finish : Bytes
        rest        = @incomplete
        @incomplete = Bytes.empty
        rest
      end
    end
  end
end
