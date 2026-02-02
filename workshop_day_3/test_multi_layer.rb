#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'redis'
require 'connection_pool'
require_relative 'lib/cache/multi_layer'

pool = ConnectionPool.new(size: 5) { Redis.new }
cache = Cache::StampedeSafeMultiLayer.new(pool, l1_max_size: 100, l1_ttl: 10)

puts "=== Multi-layer Cache Test ==="
puts

# Тест 1: Basic fetch
result = cache.fetch("user:1", expires_in: 60) do
  puts "Generating user 1..."
  { id: 1, name: "John" }
end
puts "First fetch: #{result}"

# Тест 2: L1 hit
result = cache.fetch("user:1") { raise "Should not be called!" }
puts "Second fetch (L1 hit): #{result}"

# Тест 3: Cache warming
puts "\nWarming cache..."
cache.warm({
  "products:featured" => -> {
    puts "Warming featured products..."
    [{ id: 1, name: "Product A" }, { id: 2, name: "Product B" }]
  },
  "categories:all" => -> {
    puts "Warming categories..."
    [{ id: 1, name: "Electronics" }, { id: 2, name: "Books" }]
  }
})

sleep 1  # Wait for warming

# Тест 4: Fetch warmed data
result = cache.fetch("products:featured") { raise "Should not be called!" }
puts "Warmed products: #{result}"

# Тест 5: Stats
puts "\nCache stats: #{cache.stats}"

puts "\n=== Test Complete ==="
