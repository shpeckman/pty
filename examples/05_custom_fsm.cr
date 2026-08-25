# examples/05_custom_fsm.cr
require "../src/pty"

puts "== Custom State Machine (FSM) Example =="

PTY.run("sh", ["-c", "echo 'booting...'; sleep 1; echo '{\"status\": \"ready\", \"metadata\": \"{}\"}'; echo 'trailing data'"]) do |pty|
  exp = PTY::Expect.new(pty)

  open_braces = 0
  in_string   = false
  escape      = false
  started     = false

  output = exp.expect(5.seconds) do |slice|
    char = slice.last.chr

    if in_string
      if escape
        escape = false
      elsif char == '\\'
        escape = true
      elsif char == '"'
        in_string = false
      end
    else
      case char
      when '"'
        in_string = true
      when '{'
        started = true
        open_braces += 1
      when '}'
        open_braces -= 1
      end
    end

    started && open_braces == 0
  end

  puts "Captured stream exactly up to the end of the JSON object:"
  puts output.inspect
end
