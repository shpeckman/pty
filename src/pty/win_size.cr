# src/pty/win_size.cr
module PTY
  struct WinSize
    getter cols   : Int32
    getter rows   : Int32
    getter xpixel : Int32
    getter ypixel : Int32

    def initialize(@cols : Int32, @rows : Int32,
                   @xpixel : Int32 = 0, @ypixel : Int32 = 0)
    end

    def_equals_and_hash cols, rows, xpixel, ypixel
  end
end
