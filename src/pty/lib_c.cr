# src/pty/lib_c.cr
@[Link("c")]
lib LibC
  {% unless LibC.has_constant?(:Winsize) %}
    struct Winsize
      ws_row : LibC::UShort
      ws_col : LibC::UShort
      ws_xpixel : LibC::UShort
      ws_ypixel : LibC::UShort
    end
  {% end %}

  {% unless LibC.has_method?(:ioctl) %}
    fun ioctl(fd : LibC::Int, request : LibC::ULong, ...) : LibC::Int
  {% end %}

  {% if flag?(:darwin) || flag?(:bsd) %}
    TIOCSWINSZ = (0x80000000_u64 |
                  ((sizeof(LibC::Winsize).to_u64 & 0x1fff) << 16) |
                  ('t'.ord.to_u64 << 8) | 103_u64)
    TIOCGWINSZ = (0x40000000_u64 |
                  ((sizeof(LibC::Winsize).to_u64 & 0x1fff) << 16) |
                  ('t'.ord.to_u64 << 8) | 104_u64)
  {% elsif flag?(:solaris) %}
    TIOCSWINSZ = 0x5467_u64
    TIOCGWINSZ = 0x5468_u64
  {% else %}
    TIOCSWINSZ = 0x5414_u64
    TIOCGWINSZ = 0x5413_u64
  {% end %}
end

@[Link("util")]
lib LibC
  {% unless LibC.has_method?(:openpty) %}
    fun openpty(amaster : LibC::Int*, aslave : LibC::Int*, name : LibC::Char*,
                termp : Void*, winp : LibC::Winsize*) : LibC::Int
  {% end %}
end
