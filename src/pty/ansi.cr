# src/pty/ansi.cr
module PTY::ANSI
  abstract struct Token
  end

  struct Text < Token
    getter data : String

    def initialize(@data : String)
    end
  end

  struct CSI < Token
    getter parameters   : Array(Int32?)
    getter intermediate : String
    getter final_char   : Char

    def initialize(@parameters : Array(Int32?), @intermediate : String, @final_char : Char)
    end
  end

  struct OSC < Token
    getter payload : String

    def initialize(@payload : String)
    end
  end

  struct StringSequence < Token
    getter kind    : Char
    getter payload : String

    def initialize(@kind : Char, @payload : String)
    end
  end

  struct Escape < Token
    getter intermediate : String
    getter final_char   : Char

    def initialize(@intermediate : String, @final_char : Char)
    end
  end
end
