require 'faraday'
require 'oj'
require 'thread'

module Gateway
  class Proxy
    def initialize
      @connections = {}
      @connection_counts = Hash.new(0)
      @mutex = Mutex.new
    end

    def call(env)
      backend = env['gateway.backend']

      unless backend
        return [500, { 'content-type' => 'application/json' },
                ['{"error": "internal_error", "message": "No backend configured"}']]
      end

      Gateway::ConnectionTracker.increment(backend)
      @mutex.synchronize { @connection_counts[backend] += 1 }

      begin
        response = proxy_request(backend, env)

        headers = {}
        response.headers.each do |key, value|
          headers[key.downcase] = value
        end
        headers.delete('transfer-encoding')

        [response.status, headers, [response.body || '']]
      rescue Faraday::Error => e
        if e.wrapped_exception.is_a?(Net::CircuitOpenError)
          raise Semian::OpenCircuitError.new("Circuit open for #{backend}")
        end
        handle_proxy_error(e)
      ensure
        @mutex.synchronize { @connection_counts[backend] -= 1 }
        Gateway::ConnectionTracker.decrement(backend)
      end
    end

    private

    def adaptive_timeout(backend)
      base_timeout = 5
      current_load = @connection_counts[backend]

      timeout = base_timeout * (1 + current_load / 20.0)

      puts "[TIMEOUT DEBUG] Backend: #{backend} | Load: #{current_load} | Applied Timeout: #{timeout.round(2)}s"
      timeout
    end

    def proxy_request(backend, env)
      conn = connection_for(backend)

      conn.options.timeout = adaptive_timeout(backend)

      method = env['REQUEST_METHOD'].downcase.to_sym
      path = env['PATH_INFO']
      query = env['QUERY_STRING']
      full_path = query.empty? ? path : "#{path}?#{query}"

      conn.run_request(method, full_path, request_body(env), proxy_headers(env))
    end

    def connection_for(backend)
      @connections[backend] ||= Faraday.new(url: backend) do |f|
        f.options.open_timeout = 5
        f.adapter :net_http
      end
    end

    def request_body(env)
      return nil unless %w[POST PUT PATCH].include?(env['REQUEST_METHOD'])
      env['rack.input'].read.tap { env['rack.input'].rewind }
    end

    def proxy_headers(env)
      headers = {}

      # Копируем нужные заголовки
      env.each do |key, value|
        next unless key.start_with?('HTTP_')
        next if %w[HTTP_HOST HTTP_CONNECTION].include?(key)

        header_name = key.sub('HTTP_', '').split('_').map(&:capitalize).join('-')
        headers[header_name] = value
      end

      # Добавляем Content-Type если есть
      headers['Content-Type'] = env['CONTENT_TYPE'] if env['CONTENT_TYPE']

      # Добавляем X-Forwarded headers
      headers['X-Forwarded-For'] = env['REMOTE_ADDR']
      headers['X-Forwarded-Host'] = env['HTTP_HOST']
      headers['X-Forwarded-Proto'] = env['rack.url_scheme']

      headers
    end

    def handle_proxy_error(error)
      case error
      when Faraday::TimeoutError
        [504, { 'content-type' => 'application/json' },
         ['{"error": "gateway_timeout", "message": "Backend did not respond in time"}']]
      when Faraday::ConnectionFailed
        [502, { 'content-type' => 'application/json' },
         ['{"error": "bad_gateway", "message": "Could not connect to backend"}']]
      else
        [500, { 'content-type' => 'application/json' },
         [%Q({"error": "internal_error", "message": "#{error.message}"})]]
      end
    end
  end
end
