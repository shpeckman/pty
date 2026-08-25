# src/pty/expect.cr
module PTY
  class ExpectTimeoutError < IO::TimeoutError
    getter buffer : String

    def initialize(message : String, @buffer : String)
      super(message)
    end
  end

  class Expect
    getter io : IO

    def initialize(@io : IO)
    end

    def send_line(line : String) : Nil
      @io.print(line)
      @io.print('\n')
      @io.flush
    end

    def expect(pattern : String, timeout : Time::Span? = nil) : String?
      needle = pattern.to_slice
      size   = needle.size

      scan(pattern, timeout) do |slice|
        slice.size >= size && slice[slice.size - size, size] == needle
      end
    end

    def expect(pattern : Regex, timeout : Time::Span? = nil) : String?
      scan(pattern, timeout) do |slice|
        !pattern.match(String.new(slice)).nil?
      end
    end

    def expect(timeout : Time::Span? = nil, & : Bytes -> Bool) : String?
      scan(nil, timeout) do |slice|
        yield slice
      end
    end

    private def scan(pattern, timeout : Time::Span?, & : Bytes -> Bool) : String?
      deadline = timeout ? Time.instant + timeout : nil
      fd       = @io.as?(IO::FileDescriptor)
      original = fd.try(&.read_timeout)
      buffer   = IO::Memory.new(256)

      begin
        loop do
          if deadline
            remaining = deadline - Time.instant
            if remaining <= Time::Span.zero
              raise IO::TimeoutError.new("expect absolute timeout reached")
            end
            fd.try(&.read_timeout = remaining)
          end

          char = @io.read_char
          break unless char
          buffer << char

          slice = buffer.to_slice
          return String.new(slice) if yield slice
        end
        nil
      rescue IO::TimeoutError
        msg = pattern.nil? ? "custom block" : "pattern: #{pattern.inspect}"
        raise ExpectTimeoutError.new("Timeout waiting for #{msg}",
          String.new(buffer.to_slice))
      ensure
        fd.try(&.read_timeout = original)
      end
    end
  end
end
