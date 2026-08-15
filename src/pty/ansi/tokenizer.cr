# src/pty/ansi/tokenizer.cr
require "../ansi"
require "./scanner"

module PTY::ANSI
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
