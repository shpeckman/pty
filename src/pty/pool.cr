# src/pty/pool.cr
require "./session"
require "./expect"

module PTY
  class Pool
    getter sessions = {} of String => Session
    getter expects  = {} of String => Expect

    def spawn(name : String, command : String, args : Enumerable(String)? = nil,
              env : Process::Env = nil, clear_env : Bool = false,
              shell : Bool = false, chdir : Path | String? = nil,
              cols : Int32 = 80, rows : Int32 = 24,
              xpixel : Int32 = 0, ypixel : Int32 = 0) : Session
      session = PTY.spawn(
        command, args,
        env: env, clear_env: clear_env,
        shell: shell, chdir: chdir,
        cols: cols, rows: rows,
        xpixel: xpixel, ypixel: ypixel
      )
      @sessions[name] = session
      @expects[name] = Expect.new(session)
      session
    end

    def broadcast(line : String) : Nil
      @expects.each_value &.send_line(line)
    end

    def expect_all(pattern : String | Regex, timeout : Time::Span? = nil) : Hash(String, String?)
      results = {} of String => String?
      channel = Channel({String, String?}).new

      @expects.each do |name, exp|
        ::spawn do
          begin
            channel.send({name, exp.expect(pattern, timeout)})
          rescue IO::TimeoutError
            channel.send({name, nil})
          rescue IO::Error
            channel.send({name, nil})
          end
        end
      end

      @sessions.size.times do
        name, res = channel.receive
        results[name] = res
      end

      results
    end

    def expect_all(timeout : Time::Span? = nil, &block : Bytes -> Bool) : Hash(String, String?)
      results = {} of String => String?
      channel = Channel({String, String?}).new

      @expects.each do |name, exp|
        ::spawn do
          begin
            channel.send({name, exp.expect(timeout, &block)})
          rescue IO::TimeoutError
            channel.send({name, nil})
          rescue IO::Error
            channel.send({name, nil})
          end
        end
      end

      @sessions.size.times do
        name, res = channel.receive
        results[name] = res
      end

      results
    end

    def wait_all : Hash(String, Process::Status)
      statuses = {} of String => Process::Status
      @sessions.each do |name, session|
        statuses[name] = session.wait
      end
      statuses
    end

    def close_all : Nil
      @sessions.each_value do |session|
        session.close unless session.closed?
      end
      @sessions.clear
      @expects.clear
    end
  end
end
