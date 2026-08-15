# examples/05_ansi_filter.cr
require "../src/pty"

puts "== Direct Byte Filtering (Standard) =="
raw_bytes   = "Raw \e[1;31mColor\e[0m and \e]0;OSC Title\x07Text".to_slice
filter      = PTY::ANSI::Filter.new
clean_bytes = filter.call(raw_bytes)
puts "Original : #{String.new(raw_bytes).inspect}"
puts "Filtered : #{String.new(clean_bytes).inspect}\n\n"

puts "== Direct Byte Filtering (DCS, APC, and 8-bit C1) =="
adv_bytes = "Hello\ePdevice_string\e\\ \x9B32m8-bit Color\x9B0m \x9D0;8-bit OSC\x9CWorld".to_slice
filter    = PTY::ANSI::Filter.new
clean_adv = filter.call(adv_bytes)
puts "Original : #{String.new(adv_bytes).inspect}"
puts "Filtered : #{String.new(clean_adv).inspect}\n\n"

puts "== Live PTY Output =="
STDOUT.print("Raw      : ")
STDOUT.flush
PTY.run("printf", ["\\e[31mRed Text\\e[0m and \\e[32mGreen Text\\e[0m\\n"]) do |pty|
  pty.pump(output: STDOUT)
end

STDOUT.print("Filtered : ")
STDOUT.flush
PTY.run("printf", ["\\e[31mRed Text\\e[0m and \\e[32mGreen Text\\e[0m\\n"]) do |pty|
  pty.pump(output: STDOUT, on_output: PTY::ANSI::Filter.new)
end
puts

puts "== Capturing Clean Text =="
PTY.run("ls", ["--color=always"]) do |pty|
  buffer = IO::Memory.new
  pty.pump(output: buffer, on_output: PTY::ANSI::Filter.new)

  lines = buffer.to_s.lines
  puts "Captured #{lines.size} stripped lines."
  lines.first(3).each { |line| puts "  #{line.inspect}" }
end
puts

puts "== Chained with LineFilter =="

class CleanPrefixFilter < PTY::Filter
  @ansi = PTY::ANSI::Filter.new
  @line : PTY::LineFilter

  def initialize
    @line = PTY::LineFilter.new do |line|
      "> #{String.new(line)}".to_slice
    end
  end

  def call(chunk : Bytes) : Bytes
    @line.call(@ansi.call(chunk))
  end

  def finish : Bytes
    @line.finish
  end
end

PTY.run("printf", ["\\e[34mLine 1\\e[0m\\n\\e[35mLine 2\\e[0m\\n"]) do |pty|
  pty.pump(output: STDOUT, on_output: CleanPrefixFilter.new)
end
