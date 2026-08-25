# examples/04_pool.cr
require "../src/pty"

puts "== Multi-PTY Multiplexing Example =="

pool = PTY::Pool.new

puts ">> Spawning interactive sessions..."
pool.spawn("server_alpha", "sh", ["-i"], env: {"PS1" => "PROMPT> "})
pool.spawn("server_beta", "sh", ["-i"], env: {"PS1" => "PROMPT> "})
pool.spawn("server_gamma", "sh", ["-i"], env: {"PS1" => "PROMPT> "})

puts ">> Waiting for all prompts to become ready..."
pool.expect_all("PROMPT> ")

puts ">> Broadcasting a command to all sessions..."
pool.broadcast("expr 100 + 42")

puts ">> Collecting results..."
results = pool.expect_all("PROMPT> ", 5.seconds)

puts "\n== Results =="
results.each do |node, output|
  clean_output = output ? output.strip : "Timeout or Error"

  puts "[#{node}]"
  clean_output.each_line do |line|
    puts "  #{line}"
  end
  puts
end

puts ">> Shutting down..."
pool.broadcast("exit")
pool.wait_all
pool.close_all

puts "Done."
