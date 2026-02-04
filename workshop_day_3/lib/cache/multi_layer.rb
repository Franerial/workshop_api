# frozen_string_literal: true

require 'oj'
require 'connection_pool'
require 'concurrent'

module Cache
  class CacheMetrics
    def initialize
      @hits = Concurrent::Hash.new(0)
      @misses = Concurrent::AtomicFixnum.new(0)
      @warms = Concurrent::AtomicFixnum.new(0)
    end

    def record_hit(layer, key)
      @hits[layer.to_s] += 1
    end

    def record_miss(key)
      @misses.increment
    end

    def record_warm(key)
      @warms.increment
    end

    def stats
      total_hits = @hits.values.sum
      total = total_hits + @misses.value

      {
        l1_hits: @hits['l1'],
        l2_hits: @hits['l2'],
        misses: @misses.value,
        warms: @warms.value,
        hit_rate: total > 0 ? (total_hits.to_f / total * 100).round(2) : 0,
        l1_hit_rate: total > 0 ? (@hits['l1'].to_f / total * 100).round(2) : 0
      }
    end
  end

  class MultiLayer
    # L1: In-memory (per-process)
    # L2: Redis (shared)

    def initialize(redis_pool, l1_max_size: 1000, l1_ttl: 60)
      @redis_pool = redis_pool
      @l1_cache = Concurrent::Map.new
      @l1_max_size = l1_max_size
      @l1_ttl = l1_ttl
      @l1_timestamps = Concurrent::Map.new
      @metrics = CacheMetrics.new
    end

    def fetch(key, expires_in: 3600, l1_ttl: nil, &block)
      l1_ttl ||= @l1_ttl

      # L1: Check in-memory cache
      l1_result = l1_get(key)
      if l1_result
        @metrics.record_hit(:l1, key)
        return l1_result
      end

      # L2: Check Redis
      l2_result = l2_get(key)
      if l2_result
        @metrics.record_hit(:l2, key)
        # Promote to L1
        l1_set(key, l2_result, l1_ttl)
        return l2_result
      end

      # Cache miss — generate value
      @metrics.record_miss(key)

      value = yield

      # Store in both layers
      l2_set(key, value, expires_in)
      l1_set(key, value, l1_ttl)

      value
    end

    def delete(key)
      l1_delete(key)
      l2_delete(key)
    end

    def warm(keys_with_generators)
      # Прогреваем кэш в background
      keys_with_generators.each do |key, generator|
        Thread.new do
          begin
            value = generator.call
            l2_set(key, value, 3600)
            l1_set(key, value, @l1_ttl)
            @metrics.record_warm(key)
          rescue => e
            puts "[CacheWarming] Error warming #{key}: #{e.message}"
          end
        end
      end
    end

    def stats
      @metrics.stats
    end

    private

    # === L1: In-memory ===

    def l1_get(key)
      entry = @l1_cache[key]
      return nil unless entry

      # Check TTL
      timestamp = @l1_timestamps[key]
      if timestamp && Time.now - timestamp > @l1_ttl
        l1_delete(key)
        return nil
      end

      entry
    end

    def l1_set(key, value, ttl)
      # Evict if full (простой LRU через удаление старейшего)
      if @l1_cache.size >= @l1_max_size
        oldest_key = @l1_timestamps.min_by { |_, v| v }&.first
        l1_delete(oldest_key) if oldest_key
      end

      @l1_cache[key] = value
      @l1_timestamps[key] = Time.now
    end

    def l1_delete(key)
      @l1_cache.delete(key)
      @l1_timestamps.delete(key)
    end

    # === L2: Redis ===

    def l2_get(key)
      @redis_pool.with do |redis|
        raw = redis.get("cache:#{key}")
        return nil unless raw

        Oj.load(raw, symbol_keys: true)
      end
    rescue => e
      puts "[Cache] L2 read error: #{e.message}"
      nil
    end

    def l2_set(key, value, expires_in)
      @redis_pool.with do |redis|
        redis.setex("cache:#{key}", expires_in, Oj.dump(value))
      end
    rescue => e
      puts "[Cache] L2 write error: #{e.message}"
    end

    def l2_delete(key)
      @redis_pool.with do |redis|
        redis.del("cache:#{key}")
      end
    end
  end

  class StampedeSafeMultiLayer < MultiLayer
    def initialize(redis_pool, **options)
      super
      @locks = Concurrent::Map.new
    end

    def fetch(key, expires_in: 3600, l1_ttl: nil, &block)
      l1_ttl ||= @l1_ttl

      # L1 check
      l1_result = l1_get(key)
      if l1_result
        @metrics.record_hit(:l1, key)
        return l1_result
      end

      # L2 check
      l2_result = l2_get(key)
      if l2_result
        @metrics.record_hit(:l2, key)
        l1_set(key, l2_result, l1_ttl)
        return l2_result
      end

      @metrics.record_miss(key)

      # Cache miss — need to generate, but with lock
      acquire_generation_lock(key) do
        # Double-check after getting lock
        l2_result = l2_get(key)
        return l2_result if l2_result

        # Generate value
        value = yield

        l2_set(key, value, expires_in)
        l1_set(key, value, l1_ttl)

        value
      end
    end

    private

    def acquire_generation_lock(key)
      lock_key = "lock:cache:#{key}"

      # Try to acquire lock
      acquired = @redis_pool.with do |redis|
        redis.set(lock_key, "1", nx: true, ex: 30)
      end

      if acquired
        begin
          yield
        ensure
          @redis_pool.with { |redis| redis.del(lock_key) }
        end
      else
        # Someone else is generating — wait for result
        wait_for_value(key)
      end
    end

    def wait_for_value(key)
      deadline = Time.now + 5  # 5 second timeout

      while Time.now < deadline
        value = l2_get(key)
        return value if value
        sleep 0.05
      end

      raise "Timeout waiting for cache generation"
    end
  end
end
