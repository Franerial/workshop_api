require 'semian'
require 'semian/net_http'

module Gateway
  module Middleware
    class SemianCircuitBreaker
      BACKEND_ROUTES = {
        'localhost:3001' => 'users_service',
        'localhost:3011' => 'users_service',
        'localhost:3002' => 'orders_service',
        'localhost:3003' => 'products_service',
        'localhost:3013' => 'products_service'
      }.freeze

      CIRCUIT_CONFIG = {
        'users_service' => { 
          error_threshold: 3, 
          error_timeout: 10,
          error_threshold_timeout: 60,
          timeout: 10,
          tickets: 20
        },
        'orders_service' => { 
          error_threshold: 5, 
          error_timeout: 15,
          error_threshold_timeout: 60,
          timeout: 15,
          tickets: 10
        },
        'products_service' => { 
          error_threshold: 3,
          error_timeout: 10,
          error_threshold_timeout: 60,
          timeout: 10,
          tickets: 15
        }
      }.freeze

      def initialize(app)
        @app = app
        configure_semian
      end

      def call(env)
        begin
          @app.call(env)
        rescue Semian::OpenCircuitError => e
          handle_open_circuit(env, e)
        end
      end

      private

      def configure_semian
        Semian::NetHTTP.semian_configuration = proc do |host, port|
          service_name = circuit_name_for(host, port)
          config = CIRCUIT_CONFIG[service_name]

          {
            name: "#{host}_#{port}", 
            circuit_breaker: true,
            bulkhead: true,
            success_threshold: 2,
            error_threshold: config[:error_threshold],
            error_timeout: config[:error_timeout],
            error_threshold_timeout: config[:error_threshold_timeout],
            tickets: config[:tickets]
          }
        end
      end

      def circuit_name_for(host, port)
        BACKEND_ROUTES["#{host}:#{port}"]
      end

      def handle_open_circuit(env, error)
        [
          503, 
          { 
            'content-type' => 'application/json',
          }, 
          [{ 
            error: "service_unavailable", 
            message: "Circuit is open: #{error.message}"
          }.to_json]
        ]
      end
    end
  end
end
