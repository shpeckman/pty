# spec/pool_spec.cr
require "./spec_helper"

describe PTY::Pool do
  it "spawns and tracks sessions" do
    pool = PTY::Pool.new
    pool.spawn("node1", "echo", ["hello"])
    pool.spawn("node2", "echo", ["world"])

    pool.sessions.size.should eq(2)
    pool.sessions.has_key?("node1").should be_true
    pool.sessions.has_key?("node2").should be_true

    pool.close_all
  end

  it "broadcasts to all sessions" do
    pool = PTY::Pool.new
    pool.spawn("n1", "sh", ["-c", "read input; echo out1:$input"])
    pool.spawn("n2", "sh", ["-c", "read input; echo out2:$input"])

    pool.broadcast("test_broadcast")

    results = pool.expect_all(/out\d:test_broadcast/)
    results["n1"].should_not be_nil
    results["n1"].not_nil!.should contain("out1:test_broadcast")
    results["n2"].should_not be_nil
    results["n2"].not_nil!.should contain("out2:test_broadcast")

    pool.wait_all
    pool.close_all
  end

  it "matches expect_all patterns across multiple sessions" do
    pool = PTY::Pool.new
    pool.spawn("node1", "echo", ["ready: node1"])
    pool.spawn("node2", "echo", ["ready: node2"])

    results = pool.expect_all("ready: ")
    results["node1"].should eq("ready: ")
    results["node2"].should eq("ready: ")

    pool.wait_all
    pool.close_all
  end

  it "matches expect_all using a block" do
    pool = PTY::Pool.new
    pool.spawn("node1", "echo", ["ready: node1"])
    pool.spawn("node2", "echo", ["ready: node2"])

    target = "ready: ".to_slice
    results = pool.expect_all do |slice|
      slice.size >= target.size && slice[slice.size - target.size, target.size] == target
    end
    results["node1"].should eq("ready: ")
    results["node2"].should eq("ready: ")

    pool.wait_all
    pool.close_all
  end

  it "handles expect_all timeouts independently without crashing" do
    pool = PTY::Pool.new
    pool.spawn("fast", "echo", ["finished"])
    pool.spawn("slow", "sh", ["-c", "sleep 2; echo finished"])

    results = pool.expect_all("finished", 0.5.seconds)
    results["fast"].should_not be_nil
    results["fast"].not_nil!.should contain("finished")

    results["slow"].should be_nil

    # Clean up the slow process early
    pool.close_all
  end

  it "collects statuses when waiting for all processes" do
    pool = PTY::Pool.new
    pool.spawn("node1", "sh", ["-c", "exit 42"])
    pool.spawn("node2", "sh", ["-c", "exit 99"])

    statuses = pool.wait_all
    statuses["node1"].exit_code.should eq(42)
    statuses["node2"].exit_code.should eq(99)

    pool.close_all
  end

  it "clears the session registry on close_all" do
    pool = PTY::Pool.new
    pool.spawn("node1", "sleep", ["10"])

    pool.sessions.should_not be_empty
    pool.close_all

    pool.sessions.should be_empty
  end
end
