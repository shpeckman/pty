# src/pty/winch.cr
module PTY
  module Winch
    @@mutex    = Mutex.new
    @@handlers = {} of UInt64 => ->
    @@next_id  = 0_u64

    def self.register(&handler : ->) : UInt64
      @@mutex.synchronize do
        id = (@@next_id += 1)
        @@handlers[id] = handler
        Signal::WINCH.trap { dispatch } if @@handlers.size == 1
        id
      end
    end

    def self.unregister(id : UInt64) : Nil
      @@mutex.synchronize do
        @@handlers.delete(id)
        Signal::WINCH.reset if @@handlers.empty?
      end
    end

    def self.dispatch : Nil
      handlers = @@mutex.synchronize { @@handlers.values }
      handlers.each(&.call)
    end
  end
end
