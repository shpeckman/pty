# examples/03_expect.cr
require "../src/pty"

puts "== Expect API Example =="

PTY.run("sh", ["-i"], env: {"PS1" => "PROMPT> "}) do |pty|
  puts "Waiting for initial prompt..."

  pty.expect("PROMPT> ")

  puts ">> Connected! Sending command..."
  pty.send_line("echo 'Hello from Expect!'")

  output = pty.expect("PROMPT> ")

  puts "\n>> Captured sequence between prompts:"
  puts output.inspect

  puts "\n>> Asking the shell for math..."
  pty.send_line("expr 100 + 42")
  output = pty.expect("PROMPT> ")
  puts output.inspect

  pty.send_line("exit")
end
