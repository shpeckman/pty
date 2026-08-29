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

# Pseudo-terminal spawning and control. A `PTY::Session` is an
# `IO::FileDescriptor` bound to the master side of a pty with a child process
# attached to the slave, so any program can be driven as if it were running on
# a real terminal.
#
# Usage
# -----
#
#     session = PTY.spawn("bash", cols: 80, rows: 24)
#
#     session.print("echo hello\n")
#     session.flush
#     session.expect("hello")
#
#     session.kill
#     session.wait
#     session.close
#
# `PTY.run` scopes a session to a block and always kills, reaps, and closes it:
#
#     PTY.run("stty", ["size"], cols: 90, rows: 30) do |session|
#       session.gets_to_end.strip # => "30 90"
#     end
#
# Spawning
# --------
#
# `PTY.spawn` and `PTY.run` take the same arguments:
#
#     command        executable, or a shell line when shell: true
#     args           argument list, ignored when shell: true
#     env            extra environment variables
#     clear_env      start the child from an empty environment
#     shell          run the command through /bin/sh -c
#     chdir          working directory for the child
#     cols, rows     initial window size
#     xpixel, ypixel initial pixel dimensions
#
# When cols or rows are omitted they are inherited from STDOUT if it is a
# terminal, falling back to 80x24. The child is placed in its own session via
# setsid when available, so it owns the pty as its controlling terminal.
#
# Session
# -------
#
# `PTY::Session` inherits the full `IO::FileDescriptor` surface (`read`,
# `write`, `gets_to_end`, `read_timeout`, `sync`) and delegates `pid`,
# `exists?`, `terminated?`, and `signal` to the underlying `Process`. On top of
# that:
#
#     resize(cols, rows, xpixel = 0, ypixel = 0)  TIOCSWINSZ on the master
#     resize(win_size)                            the same, from a WinSize
#     raw!                                        cfmakeraw on the master
#     send_eof                                    write VEOF while in canonical mode
#     kill(signal = Signal::TERM)                 signal the child, ignoring errors
#     wait                                        reap and memoize Process::Status
#     close                                       kill and reap if still running
#
# Reads return 0 rather than raising once the child is gone, so `gets_to_end`
# and friends terminate cleanly instead of surfacing EIO.
#
# Expect
# ------
#
# `PTY::Expect` drives an IO with pattern matching. Sessions delegate the same
# methods, so `session.expect(...)` and `PTY::Expect.new(session).expect(...)`
# are equivalent.
#
#     session.expect("Password: ")
#     session.send_line(password)
#
# The overloads differ only in what they match and what they return:
#
#     expect(String)              the pattern, once the buffer ends with it
#     expect(Regex)               Regex::MatchData for the earliest match
#     expect(Tuple | Enumerable)  MatchResult for the first pattern to hit
#     expect(timeout, &block)     the buffer, once the block accepts it
#     expect_eof                  everything read up to EOF
#
# `MatchResult` carries `index` (position in the pattern list), `buffer` (every
# byte consumed so far), and `match` (the String or MatchData that hit).
#
# Every overload accepts an optional timeout, measured as one absolute deadline
# across the call rather than per read, and restores the IO's original
# `read_timeout` afterwards. Expiry raises `ExpectTimeoutError`; a stream that
# ends first raises `ExpectEOFError`. Both expose the partial `buffer`, and
# `expect_eof` swallows the EOF to return it.
#
# Assigning `logger` mirrors everything sent and received to an IO:
#
#     session.logger = File.open("session.log", "w")
#
# Window size
# -----------
#
# `PTY::WinSize` is a value type of `cols`, `rows`, `xpixel`, and `ypixel` with
# structural equality. `PTY.window_size` reads the size of a terminal and
# raises `IO::Error` when the descriptor is not one:
#
#     session.resize(PTY.window_size(STDOUT))
#
# `PTY.raw` puts a descriptor into raw mode for the duration of a block and
# restores the previous termios afterwards. It yields unchanged when the
# descriptor is not a terminal:
#
#     PTY.raw(STDIN) { pump }
#
# `PTY::Winch` multiplexes SIGWINCH across any number of listeners. The signal
# handler is installed on the first registration and removed with the last:
#
#     id = PTY::Winch.register { session.resize(PTY.window_size(STDOUT)) }
#     PTY::Winch.unregister(id)
#
# Proxy
# -----
#
# `PTY::Proxy` wires a session to an input and an output IO and copies in both
# directions until the child exits, returning its `Process::Status`.
#
#     PTY::Proxy.new(session).attach
#     PTY::Proxy.new(session, input: source, output: sink).pump
#
# `attach` and `intercept` are the same entry point: they optionally put the
# input descriptor into raw mode and forward SIGWINCH to the child before
# pumping. `pump` does neither, which suits in-memory IOs and tests.
#
# The output side owns the lifetime. Once the child closes the pty the input
# fiber stops at its next read, so a blocked read on STDIN cannot keep the
# proxy alive.
#
# Pool
# ----
#
# `PTY::Pool` manages named sessions and fans expect out across them.
#
#     pool = PTY::Pool.new
#     pool.spawn("web1", "ssh", ["web1"], tags: [:web])
#     pool.spawn("db1", "ssh", ["db1"], tags: [:db])
#
#     pool.broadcast("uptime", tag: :web)
#     pool.expect_all(/load average/, 5.seconds, tag: :web)
#
#     pool.wait_all
#     pool.close_all
#
# `broadcast` writes a line to each target. `expect_all` mirrors the `Expect`
# overloads, runs every session concurrently, and returns a hash keyed by name;
# sessions that time out, hit EOF, or error map to nil rather than raising, so
# one failure does not sink the batch.
#
# A tag narrows `broadcast`, `expect_all`, `wait_all`, and `close_all` to the
# sessions registered under it, and omitting it targets all of them. `sessions`
# and `expects` expose the underlying objects by name.
