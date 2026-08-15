# spec/ansi_filter_spec.cr
require "./spec_helper"

describe PTY::ANSI::Filter do
  it "passes normal text without allocation" do
    filter = PTY::ANSI::Filter.new
    input  = "Hello World\n".to_slice
    result = filter.call(input)

    String.new(result).should eq("Hello World\n")
    result.to_unsafe.should eq(input.to_unsafe)
  end

  it "strips standard CSI sequences like colors" do
    filter = PTY::ANSI::Filter.new
    result = filter.call("Hello \e[31mWorld\e[0m!".to_slice)
    String.new(result).should eq("Hello World!")
  end

  it "strips cursor movement CSI sequences" do
    filter = PTY::ANSI::Filter.new
    result = filter.call("\e[2J\e[HCleared".to_slice)
    String.new(result).should eq("Cleared")
  end

  it "strips two-byte escape sequences" do
    filter = PTY::ANSI::Filter.new
    result = filter.call("Save\e7Restore\e8Done".to_slice)
    String.new(result).should eq("SaveRestoreDone")
  end

  it "strips intermediate escape sequences" do
    filter = PTY::ANSI::Filter.new
    result = filter.call("Designate\e(BASCII".to_slice)
    String.new(result).should eq("DesignateASCII")
  end

  it "strips OSC sequences terminated by BEL" do
    filter = PTY::ANSI::Filter.new
    result = filter.call("Pre\e]0;Terminal Title\x07Post".to_slice)
    String.new(result).should eq("PrePost")
  end

  it "strips OSC sequences terminated by String Terminator" do
    filter = PTY::ANSI::Filter.new
    result = filter.call("Pre\e]0;Terminal Title\e\\Post".to_slice)
    String.new(result).should eq("PrePost")
  end

  it "maintains state across split chunks" do
    filter = PTY::ANSI::Filter.new

    res1 = filter.call("Hello \e".to_slice)
    res2 = filter.call("[3".to_slice)
    res3 = filter.call("1mW".to_slice)
    res4 = filter.call("orld".to_slice)

    String.new(res1).should eq("Hello ")
    String.new(res2).should eq("")
    String.new(res3).should eq("W")
    String.new(res4).should eq("orld")
  end

  it "optimizes and maintains state across large split CSI sequences" do
    filter = PTY::ANSI::Filter.new
    res1   = filter.call("Hello \e[3".to_slice)
    res2   = filter.call("8;2;255;100;".to_slice)
    res3   = filter.call("50mWorld".to_slice)

    String.new(res1).should eq("Hello ")
    String.new(res2).should eq("")
    String.new(res3).should eq("World")
  end

  it "recovers from partial string termination sequence" do
    filter = PTY::ANSI::Filter.new
    result = filter.call("Pre\e]0;Title\e]Wait\x07Post".to_slice)
    String.new(result).should eq("PrePost")
  end

  it "strips DCS, APC, PM, and SOS string sequences" do
    filter = PTY::ANSI::Filter.new
    result = filter.call("A\ePdevice_string\e\\B\eXstart_string\x07C\e^privacy_msg\e\\D\e_app_cmd\x07E".to_slice)
    String.new(result).should eq("ABCDE")
  end

  it "strips 8-bit C1 control sequences" do
    filter = PTY::ANSI::Filter.new
    result = filter.call("A\x9B31mB\x9D0;title\x07C\x9D0;title\x9CD".to_slice)
    String.new(result).should eq("ABCD")
  end

  it "returns empty bytes when entire chunk is filtered" do
    filter = PTY::ANSI::Filter.new
    result = filter.call("\e[31m".to_slice)
    result.should be_empty
  end
end
