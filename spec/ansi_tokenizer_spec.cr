# spec/ansi_tokenizer_spec.cr
require "./spec_helper"

describe PTY::ANSI::Tokenizer do
  it "emits Text tokens for normal strings" do
    tokenizer = PTY::ANSI::Tokenizer.new
    tokens    = Array(PTY::ANSI::Token).new

    tokenizer.feed("Hello World".to_slice) { |t| tokens << t }
    tokenizer.flush { |t| tokens << t }

    tokens.size.should eq(1)
    token = tokens.first.as(PTY::ANSI::Text)
    token.data.should eq("Hello World")
  end

  it "parses CSI sequences" do
    tokenizer = PTY::ANSI::Tokenizer.new
    tokens    = Array(PTY::ANSI::Token).new

    tokenizer.feed("A\e[1;31mB\e[mC".to_slice) { |t| tokens << t }
    tokenizer.flush { |t| tokens << t }

    tokens.size.should eq(5)
    tokens[0].as(PTY::ANSI::Text).data.should eq("A")

    csi1 = tokens[1].as(PTY::ANSI::CSI)
    csi1.parameters.should eq([1, 31])
    csi1.final_char.should eq('m')

    tokens[2].as(PTY::ANSI::Text).data.should eq("B")

    csi2 = tokens[3].as(PTY::ANSI::CSI)
    csi2.parameters.should eq([] of Int32?)
    csi2.final_char.should eq('m')

    tokens[4].as(PTY::ANSI::Text).data.should eq("C")
  end

  it "parses CSI with omitted parameters" do
    tokenizer = PTY::ANSI::Tokenizer.new
    tokens    = Array(PTY::ANSI::Token).new

    tokenizer.feed("\e[;1;;m".to_slice) { |t| tokens << t }
    tokenizer.flush { |t| tokens << t }

    csi = tokens.first.as(PTY::ANSI::CSI)
    csi.parameters.should eq([nil, 1, nil, nil])
  end

  it "parses OSC sequences" do
    tokenizer = PTY::ANSI::Tokenizer.new
    tokens    = Array(PTY::ANSI::Token).new

    tokenizer.feed("\e]0;Terminal Title\x07".to_slice) { |t| tokens << t }
    tokenizer.flush { |t| tokens << t }

    osc = tokens.first.as(PTY::ANSI::OSC)
    osc.payload.should eq("0;Terminal Title")
  end

  it "parses other string sequences like DCS" do
    tokenizer = PTY::ANSI::Tokenizer.new
    tokens    = Array(PTY::ANSI::Token).new

    tokenizer.feed("\ePtmux;\e\\".to_slice) { |t| tokens << t }
    tokenizer.flush { |t| tokens << t }

    dcs = tokens.first.as(PTY::ANSI::StringSequence)
    dcs.kind.should eq('P')
    dcs.payload.should eq("tmux;")
  end

  it "maintains state across chunks" do
    tokenizer = PTY::ANSI::Tokenizer.new
    tokens    = Array(PTY::ANSI::Token).new

    tokenizer.feed("\e".to_slice) { |t| tokens << t }
    tokenizer.feed("[".to_slice) { |t| tokens << t }
    tokenizer.feed("3".to_slice) { |t| tokens << t }
    tokenizer.feed("2".to_slice) { |t| tokens << t }
    tokenizer.feed("m".to_slice) { |t| tokens << t }
    tokenizer.flush { |t| tokens << t }

    tokens.size.should eq(1)
    csi = tokens.first.as(PTY::ANSI::CSI)
    csi.parameters.should eq([32])
    csi.final_char.should eq('m')
  end

  it "parses 8-bit C1 controls" do
    tokenizer = PTY::ANSI::Tokenizer.new
    tokens    = Array(PTY::ANSI::Token).new

    tokenizer.feed("\x9B31m\x9D0;Title\x9C".to_slice) { |t| tokens << t }
    tokenizer.flush { |t| tokens << t }

    tokens.size.should eq(2)
    tokens[0].as(PTY::ANSI::CSI).parameters.should eq([31])
    tokens[1].as(PTY::ANSI::OSC).payload.should eq("0;Title")
  end

  it "parses two-byte escapes with intermediate characters" do
    tokenizer = PTY::ANSI::Tokenizer.new
    tokens    = Array(PTY::ANSI::Token).new

    tokenizer.feed("\e(B".to_slice) { |t| tokens << t }
    tokenizer.flush { |t| tokens << t }

    esc = tokens.first.as(PTY::ANSI::Escape)
    esc.intermediate.should eq("(")
    esc.final_char.should eq('B')
  end
end
