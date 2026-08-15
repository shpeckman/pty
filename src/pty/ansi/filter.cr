# src/pty/ansi/filter.cr
require "../filter"
require "./scanner"

module PTY::ANSI
  class Filter < ::PTY::Filter
    @scanner = Scanner.new

    def call(chunk : Bytes) : Bytes
      passthrough = false
      output : IO::Memory? = nil

      @scanner.scan(chunk) do |span|
        next unless span.kind.text?

        if span.start == 0 && span.size == chunk.size
          passthrough = true
        else
          io = output ||= IO::Memory.new(chunk.size)
          io.write(chunk[span.start, span.size])
        end
      end

      return chunk if passthrough

      if io = output
        io.to_slice
      else
        Bytes.empty
      end
    end
  end
end
