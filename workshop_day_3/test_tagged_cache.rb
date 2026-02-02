#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'redis'
require 'connection_pool'
require_relative 'lib/cache/tagged_cache'

pool = ConnectionPool.new(size: 5) { Redis.new }
cache = Cache::TaggedCache.new(pool)

puts "=== Tagged Cache Test ==="
puts

# Записываем данные с тегами
cache.write("users:list",
  [{ id: 1, name: "Alice" }, { id: 2, name: "Bob" }],
  tags: ["users", "active_users"]
)

cache.write("users:1",
  { id: 1, name: "Alice", email: "alice@example.com" },
  tags: ["users", "user:1"]
)

cache.write("users:2",
  { id: 2, name: "Bob", email: "bob@example.com" },
  tags: ["users", "user:2"]
)

puts "Before invalidation:"
puts "users:list = #{cache.read('users:list', ['users'])}"
puts "users:1 = #{cache.read('users:1', ['users', 'user:1'])}"
puts "users:2 = #{cache.read('users:2', ['users', 'user:2'])}"

# Инвалидируем конкретного пользователя
cache.invalidate_tag("user:1")

puts "\nAfter invalidating user:1:"
puts "users:list = #{cache.read('users:list', ['users'])}"  # Всё ещё валиден
puts "users:1 = #{cache.read('users:1', ['users', 'user:1'])}"  # nil!
puts "users:2 = #{cache.read('users:2', ['users', 'user:2'])}"  # Всё ещё валиден

# Инвалидируем всех пользователей
cache.invalidate_tag("users")

puts "\nAfter invalidating 'users' tag:"
puts "users:list = #{cache.read('users:list', ['users'])}"  # nil!
puts "users:2 = #{cache.read('users:2', ['users', 'user:2'])}"  # nil!

puts "\n=== Test Complete ==="
