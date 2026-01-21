#!/usr/bin/env ruby
require 'net/http'
require 'json'
require 'uri'

GATEWAY_URL = 'http://localhost:4000'

def request(path, method: :get)
  uri = URI("#{GATEWAY_URL}#{path}")
  response = Net::HTTP.get_response(uri)

  {
    status: response.code.to_i,
    headers: response.to_hash,
    body: parse_json(response.body)
  }
rescue => e
  { error: e.message }
end

def parse_json(body)
  JSON.parse(body)
rescue
  body
end

def print_section(title)
  puts "\n#{'=' * 60}"
  puts "  #{title}"
  puts '=' * 60
end

def print_result(name, result)
  status = result[:status] || 'ERROR'
  puts "\n#{name}:"
  puts "  Status: #{status}"
  if result[:body].is_a?(Hash)
    puts "  Body: #{JSON.pretty_generate(result[:body]).gsub("\n", "\n  ")}"
  else
    puts "  Body: #{result[:body]}"
  end
  puts "  Request-ID: #{result[:headers]&.dig('x-request-id')&.first}"
end

# === TESTS ===

print_section "1. HEALTH CHECKS"

print_result "Liveness", request('/health/live')
print_result "Readiness", request('/health/ready')
print_result "Detailed Health", request('/health/detailed')

print_section "2. ROUTING"

print_result "Users endpoint", request('/api/users/1')
print_result "Orders endpoint", request('/api/orders/1')
print_result "Unknown endpoint", request('/unknown/path')

print_section "3. RESPONSE TRANSFORMATION"

result = request('/api/users/1')
if result[:body].is_a?(Hash)
  puts "\nResponse structure:"
  puts "  - Has 'success' key: #{result[:body].key?('success')}"
  puts "  - Has 'meta' key: #{result[:body].key?('meta')}"
  puts "  - Has 'data' or 'error' key: #{result[:body].key?('data') || result[:body].key?('error')}"
end

print_section "4. CIRCUIT BREAKER TEST"

puts "\nMaking 10 rapid requests to unavailable backend..."
puts "(Watch for circuit state changes)\n"

10.times do |i|
  result = request('/api/users/1')
  circuit_state = result[:headers]&.dig('x-circuit-state')&.first || 'unknown'
  failures = result[:headers]&.dig('x-circuit-failures')&.first || '?'

  status_emoji = case result[:status]
  when 200..299 then '✓'
  when 502 then '✗'
  when 503 then '⊘'
  else '?'
  end

  puts "  Request #{i + 1}: #{status_emoji} #{result[:status]} | Circuit: #{circuit_state} | Failures: #{failures}"
  sleep 0.3
end

print_section "5. HEADERS CHECK"

result = request('/api/users/1')
puts "\nGateway headers in response:"
%w[x-request-id x-trace-id x-api-version x-response-time x-circuit-state].each do |header|
  value = result[:headers]&.dig(header)&.first || 'not present'
  puts "  #{header}: #{value}"
end

print_section "SUMMARY"

puts "\nAll tests completed!"
puts "Check the Gateway console output for health check and circuit breaker logs."
