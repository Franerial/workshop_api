require 'bundler/setup'
require 'json'

$gateway_start_time = Time.now

require_relative 'lib/gateway/health_checker'
require_relative 'lib/gateway/load_balancer'
require_relative 'lib/gateway/health_endpoint'
require_relative 'lib/gateway/middleware/request_transformer'
require_relative 'lib/gateway/middleware/response_transformer'
require_relative 'lib/gateway/middleware/semian_circuit_breaker'
require_relative 'lib/gateway/router'
require_relative 'lib/gateway/proxy'
require_relative 'lib/gateway/connection_tracker'

# Собираем все backends из конфигурации Router
all_backends = Gateway::Router::ROUTES.values.flat_map { |r| r[:backends] }.uniq

puts "=" * 60
puts "API Gateway starting..."
puts "Configured backends: #{all_backends.join(', ')}"
puts "=" * 60

# Инициализируем компоненты
health_checker = Gateway::HealthChecker.new(all_backends)
load_balancer = Gateway::LoadBalancer.new(health_checker, strategy: :round_robin)

at_exit do
  puts "Shutting down gracefully..."
  timeout = 30
  start = Time.now

  loop do
    active = Gateway::ConnectionTracker.total
    puts "Current active connections: #{active}"
    
    break if active.zero?
    break if Time.now - start > timeout

    sleep 1
  end
  puts "Shutdown complete"
end

# Собираем middleware stack
use Gateway::HealthEndpoint, health_checker: health_checker
use Gateway::Middleware::RequestTransformer
use Gateway::Middleware::ResponseTransformer
use Gateway::Router, health_checker: health_checker, load_balancer: load_balancer
use Gateway::Middleware::SemianCircuitBreaker
run Gateway::Proxy.new
