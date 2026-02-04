# frozen_string_literal: true

require 'oj'
require 'logger'

module Observability
  class StructuredLogger
    LEVELS = {
      debug: Logger::DEBUG,
      info: Logger::INFO,
      warn: Logger::WARN,
      error: Logger::ERROR,
      fatal: Logger::FATAL
    }.freeze

    def initialize(output: $stdout, level: :info)
      @output = output
      @level = LEVELS[level] || Logger::INFO
    end

    def debug(message = nil, **fields, &block)
      log(:debug, message, **fields, &block)
    end

    def info(message = nil, **fields, &block)
      log(:info, message, **fields, &block)
    end

    def warn(message = nil, **fields, &block)
      log(:warn, message, **fields, &block)
    end

    def error(message = nil, **fields, &block)
      log(:error, message, **fields, &block)
    end

    def fatal(message = nil, **fields, &block)
      log(:fatal, message, **fields, &block)
    end

    private

    def log(level, message = nil, **fields)
      return if LEVELS[level] < @level

      entry = build_entry(level, message, fields)
      entry.merge!(yield) if block_given?

      @output.puts(Oj.dump(entry, mode: :compat))
    end

    def build_entry(level, message, fields)
      entry = {
        timestamp: Time.now.utc.iso8601(3),
        level: level.to_s.upcase,
        message: message
      }

      # Добавляем correlation context
      if defined?(RequestStore) && RequestStore.store[:trace_id]
        entry[:trace_id] = RequestStore.store[:trace_id]
        entry[:request_id] = RequestStore.store[:request_id]
        entry[:span_id] = RequestStore.store[:span_id]
      end

      # Добавляем дополнительные поля
      entry.merge!(fields)

      entry.compact
    end
  end

  # Middleware для логирования запросов
  class RequestLoggerMiddleware
    def initialize(app, logger:)
      @app = app
      @logger = logger
    end

    def call(env)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Сохраняем информацию о запросе
      request_info = extract_request_info(env)

      begin
        status, headers, body = @app.call(env)

        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

        # Логируем успешный запрос
        log_request(request_info, status, duration, headers)

        [status, headers, body]
      rescue => e
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

        # Логируем ошибку
        log_error(request_info, e, duration)

        raise
      end
    end

    private

    def extract_request_info(env)
      {
        method: env['REQUEST_METHOD'],
        path: env['PATH_INFO'],
        query: env['QUERY_STRING'],
        ip: env['HTTP_X_FORWARDED_FOR'] || env['REMOTE_ADDR'],
        user_agent: env['HTTP_USER_AGENT'],
        content_length: env['CONTENT_LENGTH']&.to_i,
        api_key_prefix: env['HTTP_X_API_KEY']&.slice(0, 8)
      }
    end

    def log_request(request_info, status, duration, headers)
      @logger.info("HTTP Request",
        event: 'http_request',
        method: request_info[:method],
        path: request_info[:path],
        query: presence(request_info[:query]),
        ip: request_info[:ip],
        user_agent: request_info[:user_agent],
        api_key_prefix: request_info[:api_key_prefix],
        status: status,
        status_class: "#{status / 100}xx",
        duration_ms: (duration * 1000).round(2),
        rate_limited: status == 429,
        cache_hit: headers['x-cache'] == 'HIT',
        user_id: RequestStore.store[:user_id]
      )
    end

    def log_error(request_info, error, duration)
      @logger.error("HTTP Request Failed",
        event: 'http_request_error',
        method: request_info[:method],
        path: request_info[:path],
        ip: request_info[:ip],
        error_class: error.class.name,
        error_message: error.message,
        error_backtrace: error.backtrace&.first(5),
        duration_ms: (duration * 1000).round(2)
      )
    end

    def presence(value)
      value.nil? || value.empty? ? nil : value
    end
  end
end
