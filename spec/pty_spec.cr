# spec/pty_spec.cr
require "./spec_helper"

describe PTY::Session do
  it "runs a simple command and captures output" do
    PTY.run("echo", ["hello"]) do |pty|
      output = pty.gets_to_end.strip
      output.should eq("hello")
    end
  end

  it "allows reading and writing" do
    pty = PTY.spawn("sh", ["-c", "read input; echo $input"])
    pty.write("test_input\n".to_slice)
    pty.flush

    output = pty.gets_to_end
    output.should contain("test_input")

    pty.wait
    pty.close
  end

  it "sets the terminal size on initialize" do
    PTY.run("stty", ["size"], cols: 90, rows: 30) do |pty|
      output = pty.gets_to_end.strip
      output.should eq("30 90")
    end
  end

  it "resizes the terminal dynamically" do
    pty = PTY.spawn("sh")
    pty.resize(100, 50)

    pty.print("stty size\n")
    pty.print("exit\n")
    pty.flush

    output = pty.gets_to_end
    output.should contain("50 100")

    pty.wait
    pty.close
  end

  it "passes environment variables" do
    PTY.run("env", env: {"TEST_PTY_ENV" => "123"}) do |pty|
      output = pty.gets_to_end
      output.should contain("TEST_PTY_ENV=123")
    end
  end

  it "clears environment variables" do
    PTY.run("env", env: {"TEST_PTY_ENV" => "123"}, clear_env: true) do |pty|
      output = pty.gets_to_end
      output.should_not contain("PATH=")
      output.should contain("TEST_PTY_ENV=123")
    end
  end

  it "changes the working directory" do
    PTY.run("pwd", chdir: "/") do |pty|
      output = pty.gets_to_end.strip
      output.should eq("/")
    end
  end

  it "kills the process and returns the status" do
    pty = PTY.spawn("sleep", ["10"])
    pty.kill
    status = pty.wait
    status.success?.should be_false
    pty.close
  end

  it "runs with shell argument" do
    PTY.run("echo hello | tr a-z A-Z", shell: true) do |pty|
      output = pty.gets_to_end.strip
      output.should eq("HELLO")
    end
  end

  it "delegates process methods to the underlying process" do
    pty = PTY.spawn("sleep", ["10"])
    pty.pid.should be > 0
    pty.exists?.should be_true
    pty.terminated?.should be_false
    pty.kill
    pty.wait
    pty.terminated?.should be_true
    pty.close
  end

  it "supports pixel dimensions in initialize and resize" do
    PTY.run("echo", ["hello"], cols: 80, rows: 24, xpixel: 640, ypixel: 480) do |pty|
      pty.resize(100, 50, 800, 600)
      output = pty.gets_to_end.strip
      output.should eq("hello")
    end
  end

  it "can send a specific signal" do
    pty = PTY.spawn("sleep", ["10"])
    pty.kill(Signal::KILL)
    status = pty.wait
    status.exit_signal?.should eq(Signal::KILL)
    pty.close
  end

  it "raises IO::Error when writing to a closed PTY" do
    pty = PTY.spawn("echo", ["hello"])
    pty.close
    expect_raises(IO::Error) do
      pty.write("test".to_slice)
    end
  end

  it "can send EOF to signal end of input" do
    pty = PTY.spawn("cat")
    pty.print("hello\n")
    pty.flush
    pty.send_eof

    output = pty.gets_to_end.strip
    output.should eq("hello\r\nhello")

    pty.wait
    pty.close
  end

  it "can set raw mode without raising" do
    PTY.run("echo", ["hello"]) do |pty|
      pty.raw!
      pty.gets_to_end.strip.should eq("hello")
    end
  end

  it "exposes the full FileDescriptor surface" do
    pty = PTY.spawn("sleep", ["10"])
    pty.fd.should be > 0
    pty.read_timeout = 5.seconds
    pty.sync = true
    pty.sync?.should be_true
    pty.kill
    pty.wait
    pty.close
  end

  it "is an IO::FileDescriptor" do
    pty = PTY.spawn("sleep", ["10"])
    pty.is_a?(IO::FileDescriptor).should be_true
    pty.kill
    pty.wait
    pty.close
  end

  describe "#expect" do
    it "matches a string pattern" do
      pty    = PTY.spawn("echo", ["hello expect world"])
      result = pty.expect("expect")
      result.should eq("hello expect")
      pty.close
    end

    it "matches a regex pattern" do
      pty    = PTY.spawn("echo", ["hello 123 world"])
      result = pty.expect(/123/)
      result.should eq("hello 123")
      pty.close
    end

    it "returns nil on EOF if pattern is not found" do
      pty    = PTY.spawn("echo", ["hello world"])
      result = pty.expect("missing")
      result.should be_nil
      pty.close
    end

    it "raises ExpectTimeoutError on timeout and provides partial buffer" do
      pty = PTY.spawn("sh", ["-c", "echo 'starting'; sleep 2; echo 'ending'"])
      expect_raises(PTY::ExpectTimeoutError, "Timeout waiting for pattern") do
        begin
          pty.expect("ending", 0.5.seconds)
        rescue ex : PTY::ExpectTimeoutError
          ex.buffer.should contain("starting")
          raise ex
        end
      end
      pty.close
    end

    it "matches a pattern after a large preamble" do
      pty    = PTY.spawn("sh", ["-c", "printf '%5000s' ''; echo MARKER"])
      result = pty.expect("MARKER")
      result.should_not be_nil
      result.not_nil!.bytesize.should be > 5000
      result.not_nil!.ends_with?("MARKER").should be_true
      pty.wait
      pty.close
    end

    it "matches a pattern containing multibyte characters" do
      pty    = PTY.spawn("echo", ["une café noire"])
      result = pty.expect("café")
      result.should eq("une café")
      pty.close
    end

    it "matches a single-character pattern" do
      pty    = PTY.spawn("echo", ["abc"])
      result = pty.expect("b")
      result.should eq("ab")
      pty.close
    end

    it "does not match a pattern longer than the available output" do
      pty    = PTY.spawn("echo", ["hi"])
      result = pty.expect("hi there friend")
      result.should be_nil
      pty.close
    end

    it "stops at the earliest regex match" do
      pty    = PTY.spawn("echo", ["aXbXc"])
      result = pty.expect(/X/)
      result.should eq("aX")
      pty.close
    end

    it "matches an anchored regex without consuming trailing output" do
      pty    = PTY.spawn("echo", ["prefix-42-suffix"])
      result = pty.expect(/\d\d/)
      result.should eq("prefix-42")
      pty.close
    end

    it "restores the original read timeout after matching" do
      pty = PTY.spawn("echo", ["hello world"])
      pty.read_timeout = 30.seconds
      pty.expect("hello", 5.seconds)
      pty.read_timeout.should eq(30.seconds)
      pty.close
    end

    it "restores the original read timeout after a timeout" do
      pty = PTY.spawn("sh", ["-c", "echo start; sleep 2"])
      pty.read_timeout = 30.seconds
      expect_raises(PTY::ExpectTimeoutError) do
        pty.expect("never", 0.3.seconds)
      end
      pty.read_timeout.should eq(30.seconds)
      pty.kill
      pty.wait
      pty.close
    end
  end

  describe "#send_line" do
    it "sends a line with a newline" do
      pty = PTY.spawn("sh", ["-c", "read input; echo \"Got: $input\""])
      pty.send_line("test expect")
      result = pty.expect("Got: test expect")
      result.should_not be_nil
      pty.close
    end
  end
end

describe PTY::WinSize do
  it "stores dimensions" do
    ws = PTY::WinSize.new(80, 24, 640, 480)
    ws.cols.should eq(80)
    ws.rows.should eq(24)
    ws.xpixel.should eq(640)
    ws.ypixel.should eq(480)
  end

  it "defaults pixel dimensions to zero" do
    ws = PTY::WinSize.new(100, 50)
    ws.xpixel.should eq(0)
    ws.ypixel.should eq(0)
  end

  it "compares by value" do
    PTY::WinSize.new(80, 24).should eq(PTY::WinSize.new(80, 24))
    PTY::WinSize.new(80, 24).should_not eq(PTY::WinSize.new(80, 25))
  end
end

describe "PTY.window_size" do
  it "raises when the fd is not a terminal" do
    reader, writer = IO.pipe
    expect_raises(IO::Error) do
      PTY.window_size(reader)
    end
    reader.close
    writer.close
  end
end

describe "PTY.raw" do
  it "yields and returns the block value when input is not a terminal" do
    reader, writer = IO.pipe
    result = PTY.raw(reader) { 42 }
    result.should eq(42)
    reader.close
    writer.close
  end
end

describe "PTY::Session#resize" do
  it "accepts a WinSize" do
    pty = PTY.spawn("sh")
    pty.resize(PTY::WinSize.new(120, 40))
    pty.print("stty size\n")
    pty.print("exit\n")
    pty.flush
    pty.gets_to_end.should contain("40 120")
    pty.wait
    pty.close
  end
end

private class UpcaseFilter < PTY::Filter
  def call(chunk : Bytes) : Bytes
    String.new(chunk).upcase.to_slice
  end
end

private class DropFilter < PTY::Filter
  def call(chunk : Bytes) : Bytes
    Bytes.empty
  end
end

private class PrefixLineFilter < PTY::LineFilter
  def on_line(line : Bytes) : Bytes
    ("> " + String.new(line)).to_slice
  end
end

private class Collector < PTY::Filter
  getter data     = IO::Memory.new
  getter finished = false

  def call(chunk : Bytes) : Bytes
    @data.write(chunk)
    chunk
  end

  def finish : Bytes
    @finished = true
    Bytes.empty
  end
end

private def with_intercept(command, args = nil, *,
                           on_input : PTY::Filter? = nil,
                           on_output : PTY::Filter? = nil,
                           feed : String? = nil, eof : Bool = false, &)
  in_r, in_w = IO.pipe
  out_r, out_w = IO.pipe
  pty      = PTY.spawn(command, args)
  captured = ""
  spawn { captured = out_r.gets_to_end }
  status = nil
  spawn do
    status = pty.intercept(input: in_r, output: out_w,
      on_input: on_input, on_output: on_output,
      raw: false, forward_winch: false)
    out_w.close
  end
  if feed
    in_w.print(feed)
    in_w.flush
  end
  sleep 0.2.seconds
  pty.send_eof if eof
  sleep 0.4.seconds
  Fiber.yield
  pty.close
  in_w.close rescue nil
  in_r.close rescue nil
  yield captured, status
end

private def intercept_within(span : Time::Span, command, args = nil, &) : Process::Status?
  in_r, in_w = IO.pipe
  out_r, out_w = IO.pipe
  pty  = PTY.spawn(command, args)
  done = Channel(Process::Status).new(1)

  spawn { out_r.gets_to_end }
  spawn do
    done.send(pty.intercept(input: in_r, output: out_w,
      raw: false, forward_winch: false))
  end

  yield in_w

  status = nil
  select
  when result = done.receive
    status = result
  when timeout(span)
  end

  pty.close
  in_w.close rescue nil
  in_r.close rescue nil
  out_w.close rescue nil

  status
end

describe "PTY::Session#intercept" do
  it "transforms output through a filter" do
    with_intercept("echo", ["hello"], on_output: UpcaseFilter.new) do |captured, _|
      captured.strip.should eq("HELLO")
    end
  end

  it "suppresses output when the filter returns empty bytes" do
    with_intercept("echo", ["hello"], on_output: DropFilter.new) do |captured, _|
      captured.strip.should be_empty
    end
  end

  it "calls finish at end of stream" do
    collector = Collector.new
    with_intercept("printf", ["a\\nb\\nc\\n"], on_output: collector) do |_, _|
    end
    collector.finished.should be_true
    collector.data.to_s.should contain("a")
    collector.data.to_s.should contain("c")
  end

  it "transforms input through a filter" do
    with_intercept("cat", on_input: UpcaseFilter.new, feed: "abc\n", eof: true) do |captured, _|
      captured.should contain("ABC")
    end
  end

  it "passes through unchanged with nil filters" do
    with_intercept("echo", ["passthrough"]) do |captured, status|
      captured.strip.should eq("passthrough")
      status.try(&.success?).should be_true
    end
  end

  it "returns when the child exits while input is still open" do
    status = intercept_within(5.seconds, "echo", ["done"]) { }
    status.should_not be_nil
    status.not_nil!.success?.should be_true
  end

  it "returns when the child exits after input has been written" do
    status = intercept_within(5.seconds, "sh", ["-c", "sleep 0.3; exit 7"]) do |input|
      input.print("ignored\n")
      input.flush
    end
    status.should_not be_nil
    status.not_nil!.exit_code.should eq(7)
  end

  it "returns when the input side fails while the child is running" do
    status = intercept_within(5.seconds, "sh", ["-c", "sleep 0.3; exit 0"]) do |input|
      input.close
    end
    status.should_not be_nil
    status.not_nil!.success?.should be_true
  end
end

describe PTY::TapFilter do
  it "observes chunks without modifying the stream" do
    seen = IO::Memory.new
    tap  = PTY::TapFilter.new { |chunk| seen.write(chunk) }
    with_intercept("echo", ["tapped"], on_output: tap) do |captured, _|
      captured.strip.should eq("tapped")
    end
    seen.to_s.should contain("tapped")
  end
end

describe PTY::LineFilter do
  it "emits complete lines and buffers the incomplete tail" do
    lf = PTY::LineFilter.new
    io = IO::Memory.new
    io.write(lf.call("hel".to_slice))
    io.write(lf.call("lo\nwor".to_slice))
    io.write(lf.finish)
    io.to_s.should eq("hello\nwor")
  end

  it "passes multiple lines through unchanged" do
    lf = PTY::LineFilter.new
    io = IO::Memory.new
    io.write(lf.call("a\nb\nc\n".to_slice))
    io.write(lf.finish)
    io.to_s.should eq("a\nb\nc\n")
  end

  it "transforms each line" do
    lf = PTY::LineFilter.new { |line| String.new(line).upcase.to_slice }
    io = IO::Memory.new
    io.write(lf.call("foo\nbar".to_slice))
    io.write(lf.finish)
    io.to_s.should eq("FOO\nBAR")
  end

  it "suppresses lines that return empty bytes" do
    lf = PTY::LineFilter.new do |line|
      String.new(line).starts_with?("secret") ? Bytes.empty : line
    end
    io = IO::Memory.new
    io.write(lf.call("keep\nsecret123\nkeep2\n".to_slice))
    io.write(lf.finish)
    io.to_s.should eq("keep\nkeep2\n")
  end

  it "reassembles lines fed one byte at a time" do
    lf = PTY::LineFilter.new
    io = IO::Memory.new
    "line1\nline2\n".each_byte { |b| io.write(lf.call(Bytes[b])) }
    io.write(lf.finish)
    io.to_s.should eq("line1\nline2\n")
  end

  it "supports subclasses overriding on_line" do
    filter = PrefixLineFilter.new
    io     = IO::Memory.new
    io.write(filter.call("x\ny".to_slice))
    io.write(filter.finish)
    io.to_s.should eq("> x\n> y")
  end

  it "works as an output filter through intercept" do
    upcase = PTY::LineFilter.new { |line| String.new(line).upcase.to_slice }
    with_intercept("printf", ["one\\ntwo\\n"], on_output: upcase) do |captured, _|
      captured.should contain("ONE")
      captured.should contain("TWO")
    end
  end
end

describe "PTY::Session#pump" do
  it "captures child output into an in-memory IO" do
    buffer = IO::Memory.new
    pty    = PTY.spawn("printf", ["a\\nb\\nc\\n"])
    status = pty.pump(output: buffer)
    pty.close
    buffer.to_s.should contain("a")
    buffer.to_s.should contain("c")
    status.success?.should be_true
  end

  it "applies an output filter while capturing to memory" do
    buffer = IO::Memory.new
    pty    = PTY.spawn("printf", ["one\\ntwo\\n"])
    upcase = PTY::LineFilter.new { |line| String.new(line).upcase.to_slice }
    pty.pump(output: buffer, on_output: upcase)
    pty.close
    buffer.to_s.should contain("ONE")
    buffer.to_s.should contain("TWO")
  end

  it "pumps input from an in-memory IO through the child" do
    source = IO::Memory.new("hello from memory\n")
    sink   = IO::Memory.new
    pty    = PTY.spawn("cat")
    spawn do
      sleep 0.2.seconds
      pty.send_eof
    end
    pty.pump(input: source, output: sink)
    pty.close
    sink.to_s.should contain("hello from memory")
  end

  it "returns the child's exit status" do
    buffer = IO::Memory.new
    pty    = PTY.spawn("sh", ["-c", "exit 3"])
    status = pty.pump(output: buffer)
    pty.close
    status.exit_code.should eq(3)
  end
end
