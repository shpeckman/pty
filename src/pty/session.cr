# src/pty/session.cr
require "./lib_c"
require "./filter"
require "./win_size"

module PTY
  class ExpectTimeoutError < IO::TimeoutError
    getter buffer : String

    def initialize(message : String, @buffer : String)
      super(message)
    end
  end

  @@winch_mutex    = Mutex.new
  @@winch_handlers = {} of UInt64 => ->
  @@winch_next_id  = 0_u64

  # :nodoc:
  def self.register_winch(&handler : ->) : UInt64
    @@winch_mutex.synchronize do
      id = (@@winch_next_id += 1)
      @@winch_handlers[id] = handler
      Signal::WINCH.trap { dispatch_winch } if @@winch_handlers.size == 1
      id
    end
  end

  # :nodoc:
  def self.unregister_winch(id : UInt64) : Nil
    @@winch_mutex.synchronize do
      @@winch_handlers.delete(id)
      Signal::WINCH.reset if @@winch_handlers.empty?
    end
  end

  # :nodoc:
  def self.dispatch_winch : Nil
    handlers = @@winch_mutex.synchronize { @@winch_handlers.values }
    handlers.each(&.call)
  end

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
    @draining = false

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

    def expect(pattern : String, timeout : Time::Span? = nil) : String?
      needle = pattern.to_slice
      size   = needle.size

      scan(pattern, timeout) do |slice|
        slice.size >= size && slice[slice.size - size, size] == needle
      end
    end

    def expect(pattern : Regex, timeout : Time::Span? = nil) : String?
      scan(pattern, timeout) do |slice|
        !pattern.match(String.new(slice)).nil?
      end
    end

    private def scan(pattern, timeout : Time::Span?, & : Bytes -> Bool) : String?
      deadline = timeout ? Time.instant + timeout : nil
      original = self.read_timeout
      buffer   = IO::Memory.new(256)

      begin
        loop do
          if deadline
            remaining = deadline - Time.instant
            if remaining <= Time::Span.zero
              raise IO::TimeoutError.new("expect absolute timeout reached")
            end
            self.read_timeout = remaining
          end

          char = read_char
          break unless char
          buffer << char

          slice = buffer.to_slice
          return String.new(slice) if yield slice
        end
        nil
      rescue IO::TimeoutError
        raise ExpectTimeoutError.new("Timeout waiting for pattern: #{pattern.inspect}",
          String.new(buffer.to_slice))
      ensure
        self.read_timeout = original
      end
    end

    def send_line(line : String) : Nil
      print(line)
      print('\n')
      flush
    end

    def attach(input : IO::FileDescriptor = STDIN,
               output : IO::FileDescriptor = STDOUT,
               raw : Bool = true,
               forward_winch : Bool = true) : Process::Status
      intercept(input: input, output: output, raw: raw, forward_winch: forward_winch)
    end

    def intercept(input : IO::FileDescriptor = STDIN,
                  output : IO::FileDescriptor = STDOUT,
                  on_input : Filter? = nil,
                  on_output : Filter? = nil,
                  raw : Bool = true,
                  forward_winch : Bool = true) : Process::Status
      winch : UInt64? = nil

      if forward_winch
        sync_winsize(output)
        winch = PTY.register_winch { sync_winsize(output) }
      end

      begin
        if raw
          PTY.raw(input) { pump(input, output, on_input, on_output) }
        else
          pump(input, output, on_input, on_output)
        end
      ensure
        PTY.unregister_winch(winch) if winch
      end
    end

    def pump(input : IO = STDIN, output : IO = STDOUT,
             on_input : Filter? = nil, on_output : Filter? = nil) : Process::Status
      proxy(input, output, on_input, on_output)
      wait
    end

    private def sync_winsize(output : IO::FileDescriptor) : Nil
      resize(PTY.window_size(output))
    rescue IO::Error
    end

    private def proxy(input : IO, output : IO,
                      on_input : Filter?, on_output : Filter?) : Nil
      done      = Channel(Exception?).new(2)
      @draining = false

      spawn do
        error = nil
        begin
          copy(self, output, on_output)
        rescue ex
          error = ex
        ensure
          @draining = true
          done.send(error)
        end
      end

      spawn do
        copy_input(input, on_input)
      rescue IO::Error
      rescue ex
        done.send(ex)
      end

      if error = done.receive
        raise error
      end
    end

    private def copy(source : IO, sink : IO, filter : Filter?) : Nil
      buffer = Bytes.new(8192)
      while (count = source.read(buffer)) > 0
        emit(sink, filter ? filter.call(buffer[0, count]) : buffer[0, count])
      end
      emit(sink, filter.finish) if filter
    end

    private def copy_input(source : IO, filter : Filter?) : Nil
      buffer = Bytes.new(8192)
      until @draining
        count = source.read(buffer)
        break if count == 0 || @draining
        emit(self, filter ? filter.call(buffer[0, count]) : buffer[0, count])
      end
      emit(self, filter.finish) if filter && !@draining
    end

    private def emit(sink : IO, bytes : Bytes) : Nil
      return if bytes.empty?
      sink.write(bytes)
      sink.flush
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
