# src/pty/expect.cr
module PTY
  class ExpectTimeoutError < IO::TimeoutError
    getter buffer : String

    def initialize(message : String, @buffer : String)
      super(message)
    end
  end

  class ExpectEOFError < IO::EOFError
    getter buffer : String

    def initialize(message : String, @buffer : String)
      super(message)
    end
  end

  struct MatchResult
    getter index  : Int32
    getter buffer : String
    getter match  : String | Regex::MatchData

    def initialize(@index : Int32, @buffer : String, @match : String | Regex::MatchData)
    end
  end

  class Expect
    getter io       : IO
    property logger : IO?

    def initialize(@io : IO)
    end

    def send_line(line : String) : Nil
      @logger.try do |log|
        log.print(line)
        log.print('\n')
        log.flush
      end
      @io.print(line)
      @io.print('\n')
      @io.flush
    end

    def expect(pattern : String, timeout : Time::Span? = nil) : String?
      needle = pattern.to_slice
      size   = needle.size

      scan(pattern, timeout) do |slice|
        if slice.size >= size && slice[slice.size - size, size] == needle
          pattern
        end
      end
    end

    def expect(pattern : Regex, timeout : Time::Span? = nil) : Regex::MatchData?
      scan(pattern, timeout) do |slice|
        pattern.match(String.new(slice))
      end
    end

    def expect(patterns : Tuple, timeout : Time::Span? = nil) : MatchResult?
      ary = [] of String | Regex
      patterns.each do |pat|
        ary << pat.as(String | Regex)
      end
      expect(ary, timeout)
    end

    def expect(patterns : Enumerable(String | Regex), timeout : Time::Span? = nil) : MatchResult?
      scan(patterns, timeout) do |slice|
        str            = String.new(slice)
        matched_result = nil

        patterns.each_with_index do |pat, idx|
          if pat.is_a?(String)
            if str.ends_with?(pat)
              matched_result = MatchResult.new(idx, str, pat)
              break
            end
          elsif pat.is_a?(Regex)
            if m = pat.match(str)
              matched_result = MatchResult.new(idx, str, m)
              break
            end
          end
        end

        matched_result
      end
    end

    def expect_eof(timeout : Time::Span? = nil) : String
      scan(nil, timeout) { false }
      ""
    rescue ex : ExpectEOFError
      ex.buffer
    end

    def expect(timeout : Time::Span? = nil, &block : Bytes -> Bool) : String?
      scan(nil, timeout) do |slice|
        if block.call(slice)
          String.new(slice)
        end
      end
    end

    private def scan(pattern, timeout : Time::Span?, &block : Bytes -> T?) : T? forall T
      deadline = timeout ? Time.instant + timeout : nil
      fd       = @io.as?(IO::FileDescriptor)
      original = fd.try(&.read_timeout)
      buffer   = IO::Memory.new(256)

      begin
        loop do
          if deadline
            remaining = deadline - Time.instant
            if remaining <= Time::Span.zero
              raise ExpectTimeoutError.new("expect absolute timeout reached", String.new(buffer.to_slice))
            end
            fd.try(&.read_timeout = remaining)
          end

          char = @io.read_char
          unless char
            raise ExpectEOFError.new("Premature EOF", String.new(buffer.to_slice))
          end

          @logger.try do |log|
            log.print(char)
            log.flush
          end

          buffer << char

          slice = buffer.to_slice
          if result = block.call(slice)
            return result
          end
        end
      rescue ex : IO::TimeoutError
        msg = pattern.nil? ? "custom block" : "pattern: #{pattern.inspect}"
        raise ExpectTimeoutError.new("Timeout waiting for #{msg}", String.new(buffer.to_slice))
      ensure
        fd.try(&.read_timeout = original)
      end
    end
  end
end
