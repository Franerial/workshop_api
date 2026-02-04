# frozen_string_literal: true

require 'concurrent'

module Observability
  # Простая реализация Histogram для percentiles
  class Histogram
    MAX_SAMPLES = 10_000

    def initialize
      @values = Concurrent::Array.new
      @sum = Concurrent::AtomicReference.new(0.0)
      @count = Concurrent::AtomicFixnum.new(0)
      @mutex = Mutex.new
    end

    def add(value)
      @count.increment
      @sum.update { |v| v + value }

      @mutex.synchronize do
        @values << value

        # Reservoir sampling для ограничения памяти
        if @values.size > MAX_SAMPLES
          @values.shift
        end
      end
    end

    def stats
      return { count: 0, sum: 0, p50: 0, p95: 0, p99: 0 } if @values.empty?

      sorted = @values.sort
      count = sorted.size

      {
        count: @count.value,
        sum: @sum.get.round(2),
        min: sorted.first.round(2),
        max: sorted.last.round(2),
        p50: percentile(sorted, 50).round(2),
        p95: percentile(sorted, 95).round(2),
        p99: percentile(sorted, 99).round(2)
      }
    end

    private

    def percentile(sorted, p)
      return sorted.first if sorted.size == 1

      rank = (p / 100.0) * (sorted.size - 1)
      lower = sorted[rank.floor]
      upper = sorted[rank.ceil]

      lower + (upper - lower) * (rank - rank.floor)
    end
  end

  class MetricsCollector
    def initialize(prefix: 'api')
      @prefix = prefix
      @counters = Concurrent::Hash.new { |h, k| h[k] = Concurrent::AtomicFixnum.new(0) }
      @gauges = Concurrent::Hash.new { |h, k| h[k] = Concurrent::AtomicReference.new(0) }
      @histograms = Concurrent::Hash.new { |h, k| h[k] = Histogram.new }
    end

    # Counter: только увеличивается
    def increment(name, value = 1, tags: {})
      key = metric_key(name, tags)
      value.times { @counters[key].increment }
    end

    # Gauge: текущее значение
    def gauge(name, value, tags: {})
      key = metric_key(name, tags)
      @gauges[key].set(value)
    end

    # Histogram: распределение значений (для percentiles)
    def histogram(name, value, tags: {})
      key = metric_key(name, tags)
      @histograms[key].add(value)
    end

    # Измерение времени выполнения
    def time(name, tags: {})
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      histogram(name, duration * 1000, tags: tags)  # в миллисекундах
      result
    end

    # Получить все метрики в Prometheus-совместимом формате
    def to_prometheus
      lines = []

      @counters.each do |key, counter|
        lines << "#{key} #{counter.value}"
      end

      @gauges.each do |key, gauge|
        lines << "#{key} #{gauge.get}"
      end

      @histograms.each do |key, histogram|
        stats = histogram.stats
        lines << "#{key}_count #{stats[:count]}"
        lines << "#{key}_sum #{stats[:sum]}"
        lines << "#{key}_p50 #{stats[:p50]}"
        lines << "#{key}_p95 #{stats[:p95]}"
        lines << "#{key}_p99 #{stats[:p99]}"
      end

      lines.join("\n")
    end

    # Получить метрики как Hash (для JSON endpoint)
    def to_h
      {
        counters: @counters.transform_values(&:value),
        gauges: @gauges.transform_values(&:get),
        histograms: @histograms.transform_values(&:stats)
      }
    end

    private

    def metric_key(name, tags)
      key = "#{@prefix}_#{name}"

      if tags.any?
        tag_str = tags.map { |k, v| "#{k}=\"#{v}\"" }.join(',')
        key = "#{key}{#{tag_str}}"
      end

      key
    end
  end

  # Middleware для сбора метрик запросов
  class MetricsMiddleware
    def initialize(app, metrics:, caches: {})
      @app = app
      @metrics = metrics
      @caches = caches
    end

    def call(env)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      path = normalize_path(env['PATH_INFO'])
      method = env['REQUEST_METHOD']

      begin
        status, headers, body = @app.call(env)
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

        # Record metrics
        record_request_metrics(method, path, status, duration)

        update_cache_metrics

        [status, headers, body]
      rescue => e
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

        # Record error metrics
        record_error_metrics(method, path, e, duration)

        raise
      end
    end

    private

    def update_cache_metrics
      # Update gauge for MultiLayer Cache
      if (multi_cache = @caches[:multi])
        @metrics.gauge('cache_hit_rate', multi_cache.stats[:hit_rate], tags: { type: 'multi_layer' })
      end

      # Update gauge for Tagged Cache
      if (tagged_cache = @caches[:tagged])
        @metrics.gauge('cache_hit_rate', tagged_cache.stats[:hit_rate], tags: { type: 'tagged' })
      end
    end

    def record_request_metrics(method, path, status, duration)
      tags = { method: method, path: path, status: status, status_class: "#{status / 100}xx" }

      # Traffic: request count
      @metrics.increment('requests_total', tags: tags)

      # Latency: response time
      @metrics.histogram('request_duration_ms', duration * 1000, tags: { method: method, path: path })

      # Errors: error count
      if status >= 500
        @metrics.increment('errors_total', tags: { method: method, path: path, type: '5xx' })
      elsif status >= 400
        @metrics.increment('errors_total', tags: { method: method, path: path, type: '4xx' })
      end
    end

    def record_error_metrics(method, path, error, duration)
      @metrics.increment('errors_total', tags: {
        method: method,
        path: path,
        type: 'exception',
        error_class: error.class.name
      })

      @metrics.histogram('request_duration_ms', duration * 1000, tags: { method: method, path: path })
    end

    def normalize_path(path)
      # /api/users/123 → /api/users/:id
      path.gsub(%r{/\d+}, '/:id')
          .gsub(%r{/[0-9a-f-]{36}}, '/:uuid')  # UUID
    end
  end

  # Endpoint для метрик
  class MetricsEndpoint
    def initialize(app, metrics:, path: '/metrics')
      @app = app
      @metrics = metrics
      @path = path
    end

    def call(env)
      if env['PATH_INFO'] == @path
        serve_metrics(env)
      else
        @app.call(env)
      end
    end

    private

    def serve_metrics(env)
      accept = env['HTTP_ACCEPT'] || ''

      if accept.include?('application/json')
        # JSON формат
        body = Oj.dump(@metrics.to_h)
        [200, { 'content-type' => 'application/json' }, [body]]
      else
        # Prometheus формат (по умолчанию)
        body = @metrics.to_prometheus
        [200, { 'content-type' => 'text/plain' }, [body]]
      end
    end
  end
end
