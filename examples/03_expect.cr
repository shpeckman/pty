# examples/03_expect.cr
require "../src/pty"

puts "== Expect API Example =="

PTY.run("sh", ["-i"], env: {"PS1" => "PROMPT> "}) do |pty|
  exp = PTY::Expect.new(pty)

  puts "Waiting for initial prompt..."
  exp.expect("PROMPT> ")

  puts ">> Connected! Sending command..."
  exp.send_line("echo 'Hello from Expect!'")

  output = exp.expect("PROMPT> ")

  puts "\n>> Captured sequence between prompts:"
  puts output.inspect

  puts "\n>> Asking the shell for math..."
  exp.send_line("expr 100 + 42")
  output = exp.expect("PROMPT> ")
  puts output.inspect

  exp.send_line("exit")
end
