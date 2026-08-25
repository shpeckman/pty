# src/pty/proxy.cr
require "./session"
require "./winch"
require "./tty"

class PTY::Proxy
  getter session : Session
  getter input   : IO
  getter output  : IO

  @draining = false

  def initialize(@session : Session, @input : IO = STDIN, @output : IO = STDOUT)
  end

  def attach(raw : Bool = true, forward_winch : Bool = true) : Process::Status
    intercept(raw: raw, forward_winch: forward_winch)
  end

  def intercept(raw : Bool = true, forward_winch : Bool = true) : Process::Status
    winch : UInt64? = nil

    if forward_winch && (out_fd = @output.as?(IO::FileDescriptor))
      sync_winsize(out_fd)
      winch = PTY::Winch.register { sync_winsize(out_fd) }
    end

    begin
      if raw && (in_fd = @input.as?(IO::FileDescriptor))
        PTY.raw(in_fd) { pump }
      else
        pump
      end
    ensure
      PTY::Winch.unregister(winch) if winch
    end
  end

  def pump : Process::Status
    proxy
    @session.wait
  end

  private def sync_winsize(out_fd : IO::FileDescriptor) : Nil
    @session.resize(PTY.window_size(out_fd))
  rescue IO::Error
  end

  private def proxy : Nil
    done      = Channel(Exception?).new(2)
    @draining = false

    spawn do
      error = nil
      begin
        copy(@session, @output)
      rescue ex
        error = ex
      ensure
        @draining = true
        done.send(error)
      end
    end

    spawn do
      copy_input(@input)
    rescue IO::Error
    rescue ex
      done.send(ex)
    end

    if error = done.receive
      raise error
    end
  end

  private def copy(source : IO, sink : IO) : Nil
    buffer = Bytes.new(8192)
    while (count = source.read(buffer)) > 0
      emit(sink, buffer[0, count])
    end
  end

  private def copy_input(source : IO) : Nil
    buffer = Bytes.new(8192)
    until @draining
      count = source.read(buffer)
      break if count == 0 || @draining
      emit(@session, buffer[0, count])
    end
  end

  private def emit(sink : IO, bytes : Bytes) : Nil
    return if bytes.empty?
    sink.write(bytes)
    sink.flush
  end
end
