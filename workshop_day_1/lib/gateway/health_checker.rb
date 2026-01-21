require 'faraday'
require 'concurrent'

module Gateway
  class HealthChecker
    HEALTH_CHECK_INTERVAL = 10  # секунды
    HEALTH_CHECK_TIMEOUT = 2    # секунды
    UNHEALTHY_THRESHOLD = 3     # сколько проверок до пометки unhealthy
    HEALTHY_THRESHOLD = 2       # сколько проверок до пометки healthy

    def initialize(backends)
      @backends = backends
      @health_status = Concurrent::Hash.new
      @failure_counts = Concurrent::Hash.new(0)
      @success_counts = Concurrent::Hash.new(0)

      # Инициализируем все как healthy
      backends.each { |b| @health_status[b] = :healthy }

      # Запускаем фоновую проверку
      start_health_checks
    end

    def healthy?(backend)
      @health_status[backend] == :healthy
    end

    def healthy_backends
      @health_status.select { |_, status| status == :healthy }.keys
    end

    def status
      @health_status.transform_values(&:to_s)
    end

    private

    def start_health_checks
      @checker_thread = Thread.new do
        loop do
          @backends.each { |backend| check_health(backend) }
          sleep HEALTH_CHECK_INTERVAL
        end
      end
    end

    def check_health(backend)
      health_url = "#{backend}/health"

      begin
        response = Faraday.get(health_url) do |req|
          req.options.timeout = HEALTH_CHECK_TIMEOUT
          req.options.open_timeout = HEALTH_CHECK_TIMEOUT
        end

        if response.success?
          record_success(backend)
        else
          record_failure(backend, "HTTP #{response.status}")
        end
      rescue Faraday::Error => e
        record_failure(backend, e.message)
      end
    end

    def record_success(backend)
      @failure_counts[backend] = 0
      @success_counts[backend] += 1

      if @health_status[backend] == :unhealthy &&
         @success_counts[backend] >= HEALTHY_THRESHOLD
        mark_healthy(backend)
      end
    end

    def record_failure(backend, reason)
      @success_counts[backend] = 0
      @failure_counts[backend] += 1

      if @health_status[backend] == :healthy &&
         @failure_counts[backend] >= UNHEALTHY_THRESHOLD
        mark_unhealthy(backend, reason)
      end
    end

    def mark_healthy(backend)
      @health_status[backend] = :healthy
      @success_counts[backend] = 0
      puts "[HealthCheck] #{backend} is now HEALTHY"
    end

    def mark_unhealthy(backend, reason)
      @health_status[backend] = :unhealthy
      @failure_counts[backend] = 0
      puts "[HealthCheck] #{backend} is now UNHEALTHY (#{reason})"
    end
  end
end
