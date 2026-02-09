require 'json'

module Gateway
  class HealthEndpoint
    def initialize(app, health_checker:)
      @app = app
      @health_checker = health_checker
    end

    def call(env)
      case env['PATH_INFO']
      when '/health'
        health_response
      when '/health/detailed'
        detailed_health_response
      when '/health/live'
        liveness_response
      when '/health/ready'
        readiness_response
      when '/health/circuits'
        circuits_status_response
      else
        @app.call(env)
      end
    end

    private

    # Базовая проверка — Gateway жив?
    def liveness_response
      [200, { 'content-type' => 'application/json' },
       [{ status: 'ok' }.to_json]]
    end

    # Готовность — есть ли хотя бы один здоровый backend?
    def readiness_response
      healthy_count = @health_checker.healthy_backends.size

      if healthy_count > 0
        [200, { 'content-type' => 'application/json' },
         [{ status: 'ready', healthy_backends: healthy_count }.to_json]]
      else
        [503, { 'content-type' => 'application/json' },
         [{ status: 'not_ready', healthy_backends: 0 }.to_json]]
      end
    end

    # Общий health — сводная информация
    def health_response
      healthy_count = @health_checker.healthy_backends.size
      total_count = @health_checker.status.size

      status = if healthy_count == total_count
        'ok'
      elsif healthy_count > 0
        'degraded'
      else
        'unhealthy'
      end

      http_status = healthy_count > 0 ? 200 : 503

      [http_status, { 'content-type' => 'application/json' },
       [{
         status: status,
         healthy_backends: healthy_count,
         total_backends: total_count
       }.to_json]]
    end

    # Детальная информация о всех backends
    def detailed_health_response
      [200, { 'content-type' => 'application/json' },
       [{
         gateway: 'ok',
         uptime: process_uptime,
         backends: @health_checker.status,
         timestamp: Time.now.iso8601
       }.to_json]]
    end

    def process_uptime
      "#{(Time.now - $gateway_start_time).round}s" if defined?($gateway_start_time)
    end

    def circuits_status_response
      circuits = {}

      resources_table = Semian.resources.instance_variable_get(:@table)

      resources_table.each do |name, resource|
        cb = resource.circuit_breaker
        next unless cb

        state_obj = cb.instance_variable_get(:@state)
        errors_window = cb.instance_variable_get(:@errors)
        successes_obj = cb.instance_variable_get(:@successes)

        circuits[name] = {
          state: state_obj.value.to_s,
          error_count: errors_window.size,
          success_count: successes_obj.instance_variable_get(:@atom).value
        }
      end

      [200, { 'content-type' => 'application/json' }, [circuits.to_json]]
    end
  end
end
