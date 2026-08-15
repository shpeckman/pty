# examples/06_ansi_tokenizer.cr
require "../src/pty"

puts "== ANSI Tokenizer Example =="
tokenizer = PTY::ANSI::Tokenizer.new
raw_data  = "Starting \e[1;31mError:\e[0m \e]0;Failed\x07Something went wrong."

puts "Raw String: #{raw_data.inspect}\n\n"
puts "Tokens:"

tokenizer.feed(raw_data.to_slice) do |token|
  case token
  when PTY::ANSI::Text
    puts "  TEXT: #{token.data.inspect}"
  when PTY::ANSI::CSI
    puts "  CSI : parameters=#{token.parameters}, final=#{token.final_char.inspect}"
  when PTY::ANSI::OSC
    puts "  OSC : payload=#{token.payload.inspect}"
  when PTY::ANSI::StringSequence
    puts "  STR : kind=#{token.kind.inspect}, payload=#{token.payload.inspect}"
  when PTY::ANSI::Escape
    puts "  ESC : intermediate=#{token.intermediate.inspect}, final=#{token.final_char.inspect}"
  end
end

tokenizer.flush do |token|
  if token.is_a?(PTY::ANSI::Text)
    puts "  TEXT: #{token.data.inspect}"
  end
end
