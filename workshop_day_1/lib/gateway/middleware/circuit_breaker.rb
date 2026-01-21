require 'concurrent'

module Gateway
  module Middleware
    class CircuitBreaker
      # Состояния circuit breaker
      CLOSED = :closed       # Нормальная работа
      OPEN = :open           # Сервис недоступен, запросы отклоняются
      HALF_OPEN = :half_open # Пробуем один запрос

      # Конфигурация для каждого backend
      CIRCUIT_CONFIG = {
        'localhost:3001' => { name: 'users_service', error_threshold: 3, timeout: 10 },
        'localhost:3002' => { name: 'orders_service', error_threshold: 5, timeout: 15 },
        'localhost:3003' => { name: 'products_service', error_threshold: 3, timeout: 10 }
      }.freeze

      def initialize(app)
        @app = app
        @circuits = Concurrent::Hash.new { |h, k| h[k] = new_circuit }
      end

      def call(env)
        backend = env['gateway.backend']
        return @app.call(env) unless backend

        circuit_key = extract_host_port(backend)
        circuit = @circuits[circuit_key]
        config = CIRCUIT_CONFIG[circuit_key] || default_config

        case circuit[:state]
        when OPEN
          if Time.now >= circuit[:retry_after]
            # Переходим в half-open, пробуем один запрос
            circuit[:state] = HALF_OPEN
            try_request(env, circuit, config)
          else
            # Сразу отклоняем
            circuit_open_response(config[:name] || circuit_key, circuit)
          end
        when HALF_OPEN
          # В half-open только один запрос за раз
          try_request(env, circuit, config)
        else # CLOSED
          try_request(env, circuit, config)
        end
      end

      private

      def try_request(env, circuit, config)
        status, headers, body = @app.call(env)

        if status >= 500
          record_failure(circuit, config)
        else
          record_success(circuit, config)
        end

        # Добавляем информацию о circuit в headers
        headers['x-circuit-state'] = circuit[:state].to_s
        headers['x-circuit-failures'] = circuit[:failure_count].to_s

        [status, headers, body]
      rescue => e
        record_failure(circuit, config)
        raise e
      end

      def record_failure(circuit, config)
        circuit[:failure_count] += 1
        circuit[:last_failure_time] = Time.now

        if circuit[:failure_count] >= config[:error_threshold]
          open_circuit(circuit, config)
        end
      end

      def record_success(circuit, config)
        if circuit[:state] == HALF_OPEN
          # Успех в half-open — закрываем circuit
          close_circuit(circuit)
        else
          # В closed состоянии сбрасываем счётчик
          circuit[:failure_count] = 0
        end
      end

      def open_circuit(circuit, config)
        circuit[:state] = OPEN
        circuit[:retry_after] = Time.now + config[:timeout]
        circuit[:failure_count] = 0
        puts "[CircuitBreaker] Circuit OPENED for #{config[:name]}"
      end

      def close_circuit(circuit)
        circuit[:state] = CLOSED
        circuit[:failure_count] = 0
        circuit[:retry_after] = nil
        puts "[CircuitBreaker] Circuit CLOSED"
      end

      def new_circuit
        {
          state: CLOSED,
          failure_count: 0,
          last_failure_time: nil,
          retry_after: nil
        }
      end

      def default_config
        { name: 'unknown', error_threshold: 5, timeout: 10 }
      end

      def extract_host_port(backend)
        uri = URI.parse(backend)
        "#{uri.host}:#{uri.port}"
      end

      def circuit_open_response(circuit_name, circuit)
        [503, {
          'content-type' => 'application/json',
          'x-circuit-state' => circuit[:state].to_s,
          'x-circuit-failures' => circuit[:failure_count].to_s
        }, [{
          error: 'service_unavailable',
          message: "Service #{circuit_name} is temporarily unavailable",
          circuit_state: 'open',
          retry_after: 10
        }.to_json]]
      end
    end
  end
end
