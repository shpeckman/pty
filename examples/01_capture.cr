# examples/01_capture.cr
require "../src/pty"

PTY.run("echo", ["hello from a pty"]) do |pty|
  puts pty.gets_to_end.strip
end

PTY.run("stty", ["size"], cols: 120, rows: 40) do |pty|
  puts "child sees terminal size: #{pty.gets_to_end.strip}"
end

pty = PTY.spawn("sh", ["-c", "read name; echo hello, $name"])
pty.print("world\n")
pty.flush
puts pty.gets_to_end.strip
pty.wait
pty.close
