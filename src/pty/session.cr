# src/pty/session.cr
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

  def self.spawn(command : String, args : Enumerable(String)? = nil,
                 env : Process::Env = nil, clear_env : Bool = false,
                 shell : Bool = false, chdir : Path | String? = nil,
                 cols : Int32 = 80, rows : Int32 = 24,
                 xpixel : Int32 = 0, ypixel : Int32 = 0) : Session
    Session.new(command, args, env: env, clear_env: clear_env,
      shell: shell, chdir: chdir, cols: cols, rows: rows,
      xpixel: xpixel, ypixel: ypixel)
  end

  def self.run(command : String, args : Enumerable(String)? = nil,
               env : Process::Env = nil, clear_env : Bool = false,
               shell : Bool = false, chdir : Path | String? = nil,
               cols : Int32 = 80, rows : Int32 = 24,
               xpixel : Int32 = 0, ypixel : Int32 = 0, &)
    session = PTY.spawn(command, args, env: env, clear_env: clear_env,
      shell: shell, chdir: chdir, cols: cols, rows: rows,
      xpixel: xpixel, ypixel: ypixel)
    begin
      yield session
    ensure
      session.kill
      session.wait
      session.close
    end
  end

  class Session < IO::FileDescriptor
    getter process : Process

    @status : Process::Status?

    def self.new(command : String, args : Enumerable(String)? = nil,
                 env : Process::Env = nil, clear_env : Bool = false,
                 shell : Bool = false, chdir : Path | String? = nil,
                 cols : Int32 = 80, rows : Int32 = 24,
                 xpixel : Int32 = 0, ypixel : Int32 = 0) : Session
      if shell
        args    = ["-c", command]
        command = "/bin/sh"
      end

      master_fd = uninitialized LibC::Int
      slave_fd = uninitialized LibC::Int

      ws = LibC::Winsize.new
      ws.ws_col = cols.to_u16
      ws.ws_row = rows.to_u16
      ws.ws_xpixel = xpixel.to_u16
      ws.ws_ypixel = ypixel.to_u16

      if LibC.openpty(pointerof(master_fd), pointerof(slave_fd),
           Pointer(LibC::Char).null, Pointer(Void).null, pointerof(ws)) != 0
        raise IO::Error.from_errno("openpty")
      end

      slave = IO::FileDescriptor.new(slave_fd)
      slave.close_on_exec = true

      process = begin
        spawn_child(command, args, slave, env, clear_env, chdir)
      rescue ex
        LibC.close(master_fd)
        slave.close rescue nil
        raise ex
      end

      slave.close

      new(master_fd, process)
    end

    protected def initialize(fd : LibC::Int, @process : Process)
      super(handle: fd)
      system_blocking_init(nil) unless closed?
      self.close_on_exec = true
    end

    private def self.spawn_child(command, args, slave, env, clear_env, chdir) : Process
      base = {input: slave, output: slave, error: slave,
              env: env, clear_env: clear_env, chdir: chdir}
      if Process.find_executable("setsid")
        setsid_args = ["-c", command]
        args.try &.each { |a| setsid_args << a }
        Process.new("setsid", setsid_args, **base)
      else
        Process.new(command, args, **base)
      end
    end

    delegate pid, terminated?, exists?, signal, to: @process

    def resize(size : WinSize) : Nil
      resize(size.cols, size.rows, size.xpixel, size.ypixel)
    end

    def resize(cols : Int32, rows : Int32, xpixel : Int32 = 0, ypixel : Int32 = 0) : Nil
      return if closed?

      ws = LibC::Winsize.new
      ws.ws_col = cols.to_u16
      ws.ws_row = rows.to_u16
      ws.ws_xpixel = xpixel.to_u16
      ws.ws_ypixel = ypixel.to_u16

      if LibC.ioctl(fd, LibC::TIOCSWINSZ, pointerof(ws)) != 0
        raise IO::Error.from_errno("ioctl(TIOCSWINSZ)")
      end
    end

    def raw! : Nil
      return if closed?

      if LibC.tcgetattr(fd, out termios) != 0
        raise IO::Error.from_errno("tcgetattr")
      end

      LibC.cfmakeraw(pointerof(termios))

      if LibC.tcsetattr(fd, LibC::TCSANOW, pointerof(termios)) != 0
        raise IO::Error.from_errno("tcsetattr")
      end
    end

    def send_eof : Nil
      return if closed?

      if LibC.tcgetattr(fd, out termios) == 0 &&
         (termios.c_lflag & LibC::ICANON) != 0
        veof = termios.c_cc[LibC::VEOF]
        write_byte(veof) unless veof == 0
      end
      flush
    end

    def kill(sig : Signal = Signal::TERM) : Nil
      @process.signal(sig) unless @process.terminated?
    rescue
    end

    def wait : Process::Status
      if status = @status
        return status
      end
      @status = @process.wait
    end

    def close : Nil
      super
    ensure
      unless @status
        kill
        wait
      end
    end

    private def unbuffered_read(slice : Bytes) : Int32
      super
    rescue ex : IO::Error
      raise ex unless ex.os_error == Errno::EIO
      0
    end
  end
end
