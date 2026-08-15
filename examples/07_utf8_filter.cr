# examples/07_utf8_filter.cr
require "../src/pty"

puts "== UTF-8 Filter Example =="

class StringUpcaseFilter < PTY::Filter
  def call(chunk : Bytes) : Bytes
    String.new(chunk).upcase.to_slice
  end
end

class SafeStringFilter < PTY::Filter
  @utf8   = PTY::UTF8::Filter.new
  @upcase = StringUpcaseFilter.new

  def call(chunk : Bytes) : Bytes
    safe_chunk = @utf8.call(chunk)
    @upcase.call(safe_chunk)
  end

  def finish : Bytes
    @upcase.call(@utf8.finish)
  end
end

chunks = [
  Bytes[0x48_u8, 0x65_u8, 0x6C_u8, 0x6C_u8, 0x6F_u8, 0x20_u8, 0xF0_u8, 0x9F_u8],
  Bytes[0x9A_u8, 0x80_u8, 0x20_u8, 0x43_u8, 0x6F_u8, 0x73_u8, 0x74_u8, 0x73_u8],
  Bytes[0x20_u8, 0xE2_u8, 0x82_u8],
  Bytes[0xAC_u8, 0x35_u8, 0x30_u8],
]

safe_filter = SafeStringFilter.new
output      = IO::Memory.new

puts "Processing split multibyte chunks safely..."
chunks.each do |chunk|
  output.write(safe_filter.call(chunk))
end
output.write(safe_filter.finish)

puts "Resulting string: #{output.to_s}"
