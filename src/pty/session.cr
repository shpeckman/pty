# src/pty/session.cr
require "./lib_c"
require "./win_size"

class PTY::Session < IO::FileDescriptor
  getter process : Process

  @status : Process::Status?
  @expect : Expect?

  def self.new(command : String, args : Enumerable(String)? = nil,
               env : Process::Env = nil, clear_env : Bool = false,
               shell : Bool = false, chdir : Path | String? = nil,
               cols : Int32? = nil, rows : Int32? = nil,
               xpixel : Int32 = 0, ypixel : Int32 = 0) : Session
    if shell
      args    = ["-c", command]
      command = "/bin/sh"
    end

    c = cols
    r = rows

    if c.nil? || r.nil?
      if STDOUT.tty?
        begin
          host_ws = PTY.window_size(STDOUT)
          c       = host_ws.cols if c.nil?
          r       = host_ws.rows if r.nil?
        rescue IO::Error
        end
      end
      c ||= 80
      r ||= 24
    end

    master_fd = uninitialized LibC::Int
    slave_fd = uninitialized LibC::Int

    ws = LibC::Winsize.new
    ws.ws_col = c.to_u16
    ws.ws_row = r.to_u16
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

  private def expect_instance : Expect
    @expect ||= Expect.new(self)
  end

  def logger=(logger : IO?) : Nil
    expect_instance.logger = logger
  end

  def logger : IO?
    expect_instance.logger
  end

  def send_line(line : String) : Nil
    expect_instance.send_line(line)
  end

  def expect(pattern : String, timeout : Time::Span? = nil) : String?
    expect_instance.expect(pattern, timeout)
  end

  def expect(pattern : Regex, timeout : Time::Span? = nil) : Regex::MatchData?
    expect_instance.expect(pattern, timeout)
  end

  def expect(patterns : Tuple, timeout : Time::Span? = nil) : MatchResult?
    expect_instance.expect(patterns, timeout)
  end

  def expect(patterns : Enumerable(String | Regex), timeout : Time::Span? = nil) : MatchResult?
    expect_instance.expect(patterns, timeout)
  end

  def expect(timeout : Time::Span? = nil, &block : Bytes -> Bool) : String?
    expect_instance.expect(timeout, &block)
  end

  def expect_eof(timeout : Time::Span? = nil) : String
    expect_instance.expect_eof(timeout)
  end

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
    # Break the circular reference for the GC
    @expect = nil
  end

  private def unbuffered_read(slice : Bytes) : Int32
    super
  rescue ex : IO::Error
    raise ex unless ex.os_error == Errno::EIO
    0
  end
end
