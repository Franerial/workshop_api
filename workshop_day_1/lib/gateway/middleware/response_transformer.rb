require 'oj'

module Gateway
  module Middleware
    class ResponseTransformer
      API_VERSION = '2024.01'.freeze

      def initialize(app)
        @app = app
      end

      def call(env)
        status, headers, body = @app.call(env)

        # Добавляем стандартные response headers
        headers['x-request-id'] = env['gateway.request_id']
        headers['x-trace-id'] = env['gateway.trace_id']
        headers['x-api-version'] = API_VERSION

        # Timing
        if env['gateway.start_time']
          latency = ((Time.now - env['gateway.start_time']) * 1000).round
          headers['x-response-time'] = "#{latency}ms"
        end

        # Трансформируем JSON body если нужно
        if json_response?(headers)
          body = transform_json_body(status, headers, body, env)
        end

        [status, headers, body]
      end

      private

      def json_response?(headers)
        content_type = headers['content-type']
        content_type&.include?('application/json')
      end

      def transform_json_body(status, headers, body, env)
        # Собираем body в строку
        body_content = ''
        body.each { |chunk| body_content << chunk }

        return [body_content] if body_content.empty?

        begin
          data = Oj.load(body_content)

          # Оборачиваем в стандартную структуру
          wrapped = wrap_response(status, data, env)

          new_body = Oj.dump(wrapped, mode: :compat)
          headers['content-length'] = new_body.bytesize.to_s

          [new_body]
        rescue Oj::ParseError
          # Если не JSON — возвращаем как есть
          [body_content]
        end
      end

      def wrap_response(status, data, env)
        if status >= 400
          wrap_error(status, data, env)
        else
          wrap_success(data, env)
        end
      end

      def wrap_success(data, env)
        {
          success: true,
          data: data,
          meta: build_meta(env)
        }
      end

      def wrap_error(status, data, env)
        {
          success: false,
          error: {
            code: data['error'] || data['code'] || error_code_for_status(status),
            message: data['message'] || data['error_description'] || 'An error occurred',
            details: data['details'] || data['errors']
          },
          meta: build_meta(env)
        }
      end

      def build_meta(env)
        {
          api_version: API_VERSION,
          request_id: env['gateway.request_id'],
          timestamp: Time.now.iso8601
        }
      end

      def error_code_for_status(status)
        case status
        when 400 then 'bad_request'
        when 401 then 'unauthorized'
        when 403 then 'forbidden'
        when 404 then 'not_found'
        when 422 then 'unprocessable_entity'
        when 429 then 'rate_limited'
        when 500 then 'internal_error'
        when 502 then 'bad_gateway'
        when 503 then 'service_unavailable'
        when 504 then 'gateway_timeout'
        else 'unknown_error'
        end
      end
    end
  end
end
