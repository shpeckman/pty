# examples/03_intercept.cr
require "../src/pty"

class Numberer < PTY::LineFilter
  @n = 0

  def on_line(line : Bytes) : Bytes
    @n += 1
    "#{@n}| #{String.new(line)}".to_slice
  end
end

puts "== tap: log every output chunk =="
PTY.run("printf", ["one\\ntwo\\nthree\\n"]) do |pty|
  log  = IO::Memory.new
  sink = IO::Memory.new
  pty.pump(output: sink, on_output: PTY::TapFilter.new { |bytes| log.write(bytes) })
  print "logged: #{log.to_s.inspect}\n"
end

puts "== rewrite: uppercase each line =="
PTY.run("printf", ["alpha\\nbeta\\n"]) do |pty|
  shout = PTY::LineFilter.new { |line| String.new(line).upcase.to_slice }
  pty.intercept(on_output: shout)
end

puts "== suppress: drop lines containing 'secret' =="
PTY.run("printf", ["public one\\nsecret token\\npublic two\\n"]) do |pty|
  redactor = PTY::LineFilter.new do |line|
    String.new(line).includes?("secret") ? Bytes.empty : line
  end
  pty.intercept(on_output: redactor)
end

puts "== stateful subclass: number each line =="
PTY.run("printf", ["first\\nsecond\\nthird\\n"]) do |pty|
  pty.intercept(on_output: Numberer.new)
end
