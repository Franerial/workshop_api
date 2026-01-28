module Gateway
  module ConnectionTracker
    @counts = Hash.new(0)
    @mutex = Mutex.new

    def self.increment(backend)
      @mutex.synchronize { @counts[backend] += 1 }
    end

    def self.decrement(backend)
      @mutex.synchronize { @counts[backend] -= 1 }
    end

    def self.total
      @mutex.synchronize { @counts.values.sum }
    end
  end
end
