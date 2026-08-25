# src/pty/tty.cr
require "./lib_c"
require "./win_size"

module PTY
  def self.window_size(io : IO::FileDescriptor) : WinSize
    window_size(io.fd)
  end

  def self.window_size(fd : Int32) : WinSize
    ws = LibC::Winsize.new
    if LibC.ioctl(fd, LibC::TIOCGWINSZ, pointerof(ws)) != 0
      raise IO::Error.from_errno("ioctl(TIOCGWINSZ)")
    end
    WinSize.new(ws.ws_col.to_i, ws.ws_row.to_i,
      ws.ws_xpixel.to_i, ws.ws_ypixel.to_i)
  end

  def self.raw(io : IO::FileDescriptor = STDIN, & : -> T) : T forall T
    if LibC.tcgetattr(io.fd, out saved) != 0
      raise IO::Error.from_errno("tcgetattr") unless Errno.value == Errno::ENOTTY
      return yield
    end

    raw = saved
    LibC.cfmakeraw(pointerof(raw))
    if LibC.tcsetattr(io.fd, LibC::TCSANOW, pointerof(raw)) != 0
      raise IO::Error.from_errno("tcsetattr")
    end

    begin
      yield
    ensure
      LibC.tcsetattr(io.fd, LibC::TCSAFLUSH, pointerof(saved))
    end
  end
end
