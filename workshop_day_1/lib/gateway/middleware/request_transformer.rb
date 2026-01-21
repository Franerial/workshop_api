require 'securerandom'

module Gateway
  module Middleware
    class RequestTransformer
      def initialize(app)
        @app = app
      end

      def call(env)
        # Генерируем correlation IDs
        request_id = env['HTTP_X_REQUEST_ID'] || SecureRandom.uuid
        trace_id = env['HTTP_X_TRACE_ID'] || SecureRandom.hex(16)

        # Сохраняем для использования в response
        env['gateway.request_id'] = request_id
        env['gateway.trace_id'] = trace_id
        env['gateway.start_time'] = Time.now

        # Добавляем internal headers для backend
        env['HTTP_X_REQUEST_ID'] = request_id
        env['HTTP_X_TRACE_ID'] = trace_id
        env['HTTP_X_GATEWAY_TIMESTAMP'] = Time.now.to_i.to_s

        # Добавляем информацию о клиенте
        env['HTTP_X_REAL_IP'] = env['REMOTE_ADDR']
        env['HTTP_X_FORWARDED_FOR'] = build_forwarded_for(env)

        @app.call(env)
      end

      private

      def build_forwarded_for(env)
        existing = env['HTTP_X_FORWARDED_FOR']
        client_ip = env['REMOTE_ADDR']

        existing ? "#{existing}, #{client_ip}" : client_ip
      end
    end
  end
end
