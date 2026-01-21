require 'net/http'
require 'json'

puts "Testing Circuit Breaker..."
puts "=" * 50

10.times do |i|
  uri = URI('http://localhost:4000/api/users/1')
  begin
    response = Net::HTTP.get_response(uri)
    circuit_state = response['x-circuit-state'] || 'unknown'
    failures = response['x-circuit-failures'] || '0'

    puts "Request #{i + 1}: HTTP #{response.code} | Circuit: #{circuit_state} | Failures: #{failures}"
  rescue => e
    puts "Request #{i + 1}: Error - #{e.message}"
  end
  sleep 0.5
end
