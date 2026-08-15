# spec/utf8_filter_spec.cr
require "./spec_helper"

describe PTY::UTF8::Filter do
  it "passes valid ascii through unchanged without allocations" do
    filter = PTY::UTF8::Filter.new
    input  = "Hello World".to_slice
    result = filter.call(input)

    result.to_unsafe.should eq(input.to_unsafe)
    String.new(result).should eq("Hello World")
  end

  it "buffers the incomplete first byte of a 2-byte character" do
    filter     = PTY::UTF8::Filter.new
    char_bytes = "é".to_slice

    res1 = filter.call(Bytes[0x61_u8, char_bytes[0]])
    String.new(res1).should eq("a")

    res2 = filter.call(Bytes[char_bytes[1], 0x62_u8])
    String.new(res2).should eq("éb")
  end

  it "buffers the incomplete parts of a 3-byte character" do
    filter     = PTY::UTF8::Filter.new
    char_bytes = "€".to_slice

    res1 = filter.call(Bytes[char_bytes[0]])
    res1.should be_empty

    res2 = filter.call(Bytes[char_bytes[1], char_bytes[2]])
    String.new(res2).should eq("€")

    res3 = filter.call(Bytes[0x20_u8, char_bytes[0], char_bytes[1]])
    String.new(res3).should eq(" ")

    res4 = filter.call(Bytes[char_bytes[2], 0x20_u8])
    String.new(res4).should eq("€ ")
  end

  it "buffers the incomplete parts of a 4-byte character" do
    filter     = PTY::UTF8::Filter.new
    char_bytes = "🚀".to_slice

    res1 = filter.call(Bytes[0x61_u8, char_bytes[0], char_bytes[1]])
    String.new(res1).should eq("a")

    res2 = filter.call(Bytes[char_bytes[2]])
    res2.should be_empty

    res3 = filter.call(Bytes[char_bytes[3], 0x62_u8])
    String.new(res3).should eq("🚀b")
  end

  it "emits remaining bytes on finish" do
    filter     = PTY::UTF8::Filter.new
    char_bytes = "é".to_slice

    filter.call(Bytes[0x61_u8, char_bytes[0]])
    rest = filter.finish

    rest.size.should eq(1)
    rest[0].should eq(char_bytes[0])
  end
end
