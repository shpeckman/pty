# src/pty/ansi/scanner.cr
module PTY::ANSI
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
end
