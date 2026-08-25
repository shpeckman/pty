# src/pty/ansi.cr
require "./filter"

module PTY::ANSI
  abstract struct Token
  end

  struct Text < Token
    getter data : String

    def initialize(@data : String)
    end
  end

  struct CSI < Token
    getter parameters : Array(Int32?), intermediate : String, final_char : Char

    def initialize(@parameters : Array(Int32?), @intermediate : String, @final_char : Char)
    end
  end

  struct OSC < Token
    getter payload : String

    def initialize(@payload : String)
    end
  end

  struct StringSequence < Token
    getter kind : Char, payload : String

    def initialize(@kind : Char, @payload : String)
    end
  end

  struct Escape < Token
    getter intermediate : String, final_char : Char

    def initialize(@intermediate : String, @final_char : Char)
    end
  end

  # :nodoc:
  class Scanner
    enum Kind
      Text
      Start
      Body
      End
      Literal
      Abort
    end

    enum Sequence
      None
      CSI
      String
      Escape
    end

    enum State
      Normal
      Escape
      Intermediate
      CSI
      String
      StringEscape
    end

    struct Span
      getter kind     : Kind
      getter sequence : Sequence
      getter start    : Int32
      getter size     : Int32
      getter byte     : UInt8

      def initialize(@kind : Kind, @sequence : Sequence, @start : Int32 = 0,
                     @size : Int32 = 0, @byte : UInt8 = 0_u8)
      end
    end

    getter state : State = State::Normal

    def reset : Nil
      @state = State::Normal
    end

    def scan(chunk : Bytes, & : Span ->) : Nil
      offset = 0

      while offset < chunk.size
        case @state
        when .normal?
          sub = chunk[offset..]
          idx = sub.index { |b| b == 0x1B_u8 || (b >= 0x90_u8 && b <= 0x9F_u8 && b != 0x9C_u8) }

          unless idx
            yield Span.new(:text, :none, offset, sub.size)
            break
          end

          yield Span.new(:text, :none, offset, idx) if idx > 0

          byte = sub[idx]
          offset += idx + 1

          case byte
          when 0x1B_u8
            @state = State::Escape
            yield Span.new(:start, :escape, byte: byte)
          when 0x9B_u8
            @state = State::CSI
            yield Span.new(:start, :csi, byte: byte)
          else
            @state = State::String
            yield Span.new(:start, :string, byte: string_kind(byte))
          end
        when .escape?
          byte = chunk[offset]
          offset += 1

          case byte
          when 0x5B_u8
            @state = State::CSI
            yield Span.new(:start, :csi, byte: byte)
          when 0x5D_u8, 0x50_u8, 0x58_u8, 0x5E_u8, 0x5F_u8
            @state = State::String
            yield Span.new(:start, :string, byte: byte)
          when 0x20_u8..0x2F_u8
            @state = State::Intermediate
            yield Span.new(:body, :escape, offset - 1, 1)
          else
            @state = State::Normal
            yield Span.new(:end, :escape, byte: byte)
          end
        when .intermediate?
          byte = chunk[offset]
          offset += 1

          case byte
          when 0x20_u8..0x2F_u8
            yield Span.new(:body, :escape, offset - 1, 1)
          when 0x30_u8..0x7E_u8
            @state = State::Normal
            yield Span.new(:end, :escape, byte: byte)
          else
            @state = State::Normal
            yield Span.new(:abort, :escape)
          end
        when .csi?
          sub = chunk[offset..]
          idx = sub.index { |b| b >= 0x40_u8 && b <= 0x7E_u8 }

          unless idx
            yield Span.new(:body, :csi, offset, sub.size)
            break
          end

          yield Span.new(:body, :csi, offset, idx) if idx > 0

          byte = sub[idx]
          offset += idx + 1
          @state = State::Normal
          yield Span.new(:end, :csi, byte: byte)
        when .string?
          sub = chunk[offset..]
          idx = sub.index { |b| b == 0x07_u8 || b == 0x1B_u8 || b == 0x9C_u8 }

          unless idx
            yield Span.new(:body, :string, offset, sub.size)
            break
          end

          yield Span.new(:body, :string, offset, idx) if idx > 0

          byte = sub[idx]
          offset += idx + 1

          if byte == 0x1B_u8
            @state = State::StringEscape
          else
            @state = State::Normal
            yield Span.new(:end, :string, byte: byte)
          end
        when .string_escape?
          byte = chunk[offset]
          offset += 1

          if byte == 0x5C_u8
            @state = State::Normal
            yield Span.new(:end, :string, byte: byte)
          else
            @state = State::String
            yield Span.new(:literal, :string, byte: 0x1B_u8)
            yield Span.new(:body, :string, offset - 1, 1)
          end
        end
      end
    end

    private def string_kind(byte : UInt8) : UInt8
      case byte
      when 0x9D_u8 then 0x5D_u8
      when 0x90_u8 then 0x50_u8
      when 0x98_u8 then 0x58_u8
      when 0x9E_u8 then 0x5E_u8
      when 0x9F_u8 then 0x5F_u8
      else              byte
      end
    end
  end

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

  class Tokenizer
    @scanner = Scanner.new
    @buffer  = IO::Memory.new
    @string_kind : Char = '\0'

    def feed(chunk : Bytes, &block : Token ->) : Nil
      @scanner.scan(chunk) do |span|
        case span.kind
        when .text?, .body?
          @buffer.write(chunk[span.start, span.size])
        when .start?
          flush_text(&block)
          @string_kind = span.byte.chr if span.sequence.string?
        when .literal?
          @buffer.write_byte(span.byte)
        when .end?
          emit(span, &block)
        when .abort?
          @buffer.clear
        end
      end
    end

    def flush(&block : Token ->) : Nil
      flush_text(&block)
      @buffer.clear
      @scanner.reset
    end

    private def emit(span : Scanner::Span, &block : Token ->) : Nil
      payload = @buffer.to_s
      @buffer.clear

      case span.sequence
      when .csi?
        block.call(build_csi(payload, span.byte.chr))
      when .string?
        if @string_kind == ']'
          block.call(OSC.new(payload))
        else
          block.call(StringSequence.new(@string_kind, payload))
        end
      when .escape?
        block.call(Escape.new(payload, span.byte.chr))
      end
    end

    private def build_csi(payload : String, final_char : Char) : CSI
      intermediate = ""
      params_str   = payload

      if idx = payload.each_char.index { |c| c.ord >= 0x20 && c.ord <= 0x2F }
        intermediate = payload[idx..]
        params_str   = payload[0, idx]
      end

      parameters = Array(Int32?).new
      unless params_str.empty?
        params_str.split(';').each do |p|
          parameters << (p.empty? ? nil : p.to_i?)
        end
      end

      CSI.new(parameters, intermediate, final_char)
    end

    private def flush_text(&block : Token ->) : Nil
      return if @buffer.empty?
      block.call(Text.new(@buffer.to_s))
      @buffer.clear
    end
  end
end
