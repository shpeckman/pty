# src/pty/pool.cr
require "./session"
require "./expect"

class PTY::Pool
  getter sessions = {} of String => Session
  getter expects  = {} of String => Expect
  getter tags     = {} of String | Symbol => Array(String)

  def spawn(name : String, command : String, args : Enumerable(String)? = nil,
            env : Process::Env = nil, clear_env : Bool = false,
            shell : Bool = false, chdir : Path | String? = nil,
            cols : Int32? = nil, rows : Int32? = nil,
            xpixel : Int32 = 0, ypixel : Int32 = 0,
            tags : Enumerable(String | Symbol) = [] of String | Symbol) : Session
    session = PTY.spawn(
      command, args,
      env: env, clear_env: clear_env,
      shell: shell, chdir: chdir,
      cols: cols, rows: rows,
      xpixel: xpixel, ypixel: ypixel
    )
    @sessions[name] = session
    @expects[name] = Expect.new(session)

    tags.each do |tag|
      @tags[tag] ||= [] of String
      @tags[tag] << name
    end

    session
  end

  def broadcast(line : String, tag : String | Symbol? = nil) : Nil
    target_names(tag).each do |name|
      @expects[name]?.try(&.send_line(line))
    end
  end

  def expect_all(pattern : String, timeout : Time::Span? = nil, tag : String | Symbol? = nil) : Hash(String, String?)
    results = {} of String => String?
    targets = target_names(tag)
    return results if targets.empty?

    channel = Channel({String, String?}).new

    targets.each do |name|
      exp = @expects[name]
      ::spawn do
        begin
          channel.send({name, exp.expect(pattern, timeout)})
        rescue IO::TimeoutError | ExpectEOFError | IO::Error
          channel.send({name, nil})
        end
      end
    end

    targets.size.times do
      name, res = channel.receive
      results[name] = res
    end

    results
  end

  def expect_all(pattern : Regex, timeout : Time::Span? = nil, tag : String | Symbol? = nil) : Hash(String, Regex::MatchData?)
    results = {} of String => Regex::MatchData?
    targets = target_names(tag)
    return results if targets.empty?

    channel = Channel({String, Regex::MatchData?}).new

    targets.each do |name|
      exp = @expects[name]
      ::spawn do
        begin
          channel.send({name, exp.expect(pattern, timeout)})
        rescue IO::TimeoutError | ExpectEOFError | IO::Error
          channel.send({name, nil})
        end
      end
    end

    targets.size.times do
      name, res = channel.receive
      results[name] = res
    end

    results
  end

  def expect_all(patterns : Tuple, timeout : Time::Span? = nil, tag : String | Symbol? = nil) : Hash(String, MatchResult?)
    results = {} of String => MatchResult?
    targets = target_names(tag)
    return results if targets.empty?

    channel = Channel({String, MatchResult?}).new

    targets.each do |name|
      exp = @expects[name]
      ::spawn do
        begin
          channel.send({name, exp.expect(patterns, timeout)})
        rescue IO::TimeoutError | ExpectEOFError | IO::Error
          channel.send({name, nil})
        end
      end
    end

    targets.size.times do
      name, res = channel.receive
      results[name] = res
    end

    results
  end

  def expect_all(patterns : Enumerable(String | Regex), timeout : Time::Span? = nil, tag : String | Symbol? = nil) : Hash(String, MatchResult?)
    results = {} of String => MatchResult?
    targets = target_names(tag)
    return results if targets.empty?

    channel = Channel({String, MatchResult?}).new

    targets.each do |name|
      exp = @expects[name]
      ::spawn do
        begin
          channel.send({name, exp.expect(patterns, timeout)})
        rescue IO::TimeoutError | ExpectEOFError | IO::Error
          channel.send({name, nil})
        end
      end
    end

    targets.size.times do
      name, res = channel.receive
      results[name] = res
    end

    results
  end

  def expect_all(timeout : Time::Span? = nil, tag : String | Symbol? = nil, &block : Bytes -> Bool) : Hash(String, String?)
    results = {} of String => String?
    targets = target_names(tag)
    return results if targets.empty?

    channel = Channel({String, String?}).new

    targets.each do |name|
      exp = @expects[name]
      ::spawn do
        begin
          channel.send({name, exp.expect(timeout, &block)})
        rescue IO::TimeoutError | ExpectEOFError | IO::Error
          channel.send({name, nil})
        end
      end
    end

    targets.size.times do
      name, res = channel.receive
      results[name] = res
    end

    results
  end

  def wait_all(tag : String | Symbol? = nil) : Hash(String, Process::Status)
    statuses = {} of String => Process::Status
    target_names(tag).each do |name|
      statuses[name] = @sessions[name].wait
    end
    statuses
  end

  def close_all(tag : String | Symbol? = nil) : Nil
    target_names(tag).each do |name|
      session = @sessions[name]
      session.close unless session.closed?
      @sessions.delete(name)
      @expects.delete(name)
      @tags.each_value &.delete(name)
    end
  end

  private def target_names(tag : String | Symbol?) : Array(String)
    return @sessions.keys unless tag
    @tags[tag]? || [] of String
  end
end
