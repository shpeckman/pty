# src/pty/utf8_filter.cr
require "./filter"

module PTY::UTF8
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
