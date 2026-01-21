require 'faraday'
require 'oj'

module Gateway
  class Proxy
    def initialize
      @connections = {}
    end

    def call(env)
      backend = env['gateway.backend']

      unless backend
        return [500, { 'content-type' => 'application/json' },
                ['{"error": "internal_error", "message": "No backend configured"}']]
      end

      # Проксируем запрос
      response = proxy_request(backend, env)

      # Формируем Rack response
      headers = {}
      response.headers.each do |key, value|
        headers[key.downcase] = value
      end
      headers.delete('transfer-encoding')  # Rack сам управляет

      [response.status, headers, [response.body || '']]
    rescue Faraday::Error => e
      handle_proxy_error(e)
    end

    private

    def proxy_request(backend, env)
      conn = connection_for(backend)

      method = env['REQUEST_METHOD'].downcase.to_sym
      path = env['PATH_INFO']
      query = env['QUERY_STRING']
      full_path = query.empty? ? path : "#{path}?#{query}"

      conn.run_request(method, full_path, request_body(env), proxy_headers(env))
    end

    def connection_for(backend)
      @connections[backend] ||= Faraday.new(url: backend) do |f|
        f.options.timeout = 10
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
