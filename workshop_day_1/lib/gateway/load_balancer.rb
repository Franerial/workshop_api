require 'concurrent'

module Gateway
  class LoadBalancer
    STRATEGIES = %i[round_robin least_connections random].freeze

    def initialize(health_checker, strategy: :round_robin)
      @health_checker = health_checker
      @strategy = strategy
      @round_robin_index = Concurrent::AtomicFixnum.new(0)
      @connection_counts = Concurrent::Hash.new(0)
    end

    def select_backend(backends)
      healthy = backends.select { |b| @health_checker.healthy?(b) }

      return nil if healthy.empty?
      return healthy.first if healthy.size == 1

      case @strategy
      when :round_robin
        round_robin_select(healthy)
      when :least_connections
        least_connections_select(healthy)
      when :random
        healthy.sample
      else
        healthy.first
      end
    end

    def record_connection_start(backend)
      @connection_counts[backend] += 1
    end

    def record_connection_end(backend)
      @connection_counts[backend] -= 1
    end

    private

    def round_robin_select(backends)
      index = @round_robin_index.increment % backends.size
      backends[index]
    end

    def least_connections_select(backends)
      backends.min_by { |b| @connection_counts[b] }
    end
  end
end
