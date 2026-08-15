# examples/04_session_logger.cr
require "../src/pty"

unless STDIN.tty? && STDOUT.tty?
  STDERR.puts "This example wraps your shell and must be run in a real terminal."
  STDERR.puts "Try: crystal run examples/04_session_logger.cr"
  exit 1
end

command = ARGV.empty? ? "bash" : ARGV.first
args    = ARGV.size > 1 ? ARGV[1..] : nil

log = File.open("session.log", "w")

PTY.run(command, args) do |pty|
  tap = PTY::TapFilter.new do |bytes|
    log.write(bytes)
    log.flush
  end
  status = pty.intercept(on_output: tap)
  log.close
  STDERR.puts "session recorded to session.log"
  exit(status.exit_code)
end
