# examples/02_proxy.cr
require "../src/pty"

command = ARGV.empty? ? "bash" : ARGV.first
args    = ARGV.size > 1 ? ARGV[1..] : nil

PTY.run(command, args) do |pty|
  status = pty.attach
  exit(status.exit_code)
end
