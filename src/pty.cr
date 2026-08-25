# src/pty.cr
require "./pty/win_size"
require "./pty/tty"
require "./pty/winch"
require "./pty/session"
require "./pty/expect"
require "./pty/proxy"
require "./pty/pool"

module PTY
  def self.spawn(command : String, args : Enumerable(String)? = nil,
                 env : Process::Env = nil, clear_env : Bool = false,
                 shell : Bool = false, chdir : Path | String? = nil,
                 cols : Int32? = nil, rows : Int32? = nil,
                 xpixel : Int32 = 0, ypixel : Int32 = 0) : Session
    Session.new(command, args, env: env, clear_env: clear_env,
      shell: shell, chdir: chdir, cols: cols, rows: rows,
      xpixel: xpixel, ypixel: ypixel)
  end

  def self.run(command : String, args : Enumerable(String)? = nil,
               env : Process::Env = nil, clear_env : Bool = false,
               shell : Bool = false, chdir : Path | String? = nil,
               cols : Int32? = nil, rows : Int32? = nil,
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
end
