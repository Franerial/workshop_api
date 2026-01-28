module Gateway
  class Router
    # Теперь backend — это массив для load balancing
    ROUTES = {
      %r{^/api/users} => {
        backends: ['http://localhost:3001', 'http://localhost:3011'],
        strip_prefix: '/api'
      },
      %r{^/api/orders} => {
        backends: ['http://localhost:3002'],
        strip_prefix: '/api'
      },
      %r{^/api/products} => {
        backends: ['http://localhost:3003', 'http://localhost:3013'],
        strip_prefix: '/api'
      }
    }.freeze

    def initialize(app, health_checker:, load_balancer:)
      @app = app
      @health_checker = health_checker
      @load_balancer = load_balancer
    end

    def call(env)
      path = env['PATH_INFO']

      return metrics_response if path == '/metrics'

      route = find_route(path)

      unless route
        return not_found_response
      end

      # Выбираем здоровый backend
      backend = @load_balancer.select_backend(route[:backends])

      unless backend
        return no_healthy_backend_response(route[:backends])
      end

      env['gateway.backend'] = backend
      env['gateway.all_backends'] = route[:backends]
      env['gateway.original_path'] = path

      if route[:strip_prefix]
        env['PATH_INFO'] = path.sub(route[:strip_prefix], '')
      end

      # Tracking connections для least_connections strategy
      @load_balancer.record_connection_start(backend)
      begin
        @app.call(env)
      ensure
        @load_balancer.record_connection_end(backend)
      end
    end

    private

    def metrics_response
      lines = []

      resources_table = Semian.resources.instance_variable_get(:@table)
      resources_table.each do |name, resource|
        cb = resource.circuit_breaker
        next unless cb

        state_value = cb.instance_variable_get(:@state).value
        is_open = (state_value == :open ? 1 : 0)
        error_count = cb.instance_variable_get(:@errors).size
        
        lines << "semian_circuit_open{service=\"#{name}\"} #{is_open}"
        lines << "semian_circuit_errors{service=\"#{name}\"} #{error_count}"
      end

      response_body = lines.any? ? lines.join("\n") + "\n" : ""

      [200, { 'content-type' => 'text/plain; version=0.0.4' }, [response_body]]
    end

    def find_route(path)
      ROUTES.find { |pattern, _| path.match?(pattern) }&.last
    end

    def not_found_response
      [404, { 'content-type' => 'application/json' },
       ['{"error": "not_found", "message": "No route matches this path"}']]
    end

    def no_healthy_backend_response(backends)
      status_info = backends.map do |b|
        { url: b, healthy: @health_checker.healthy?(b) }
      end

      [503, { 'content-type' => 'application/json' },
       [{
         error: 'service_unavailable',
         message: 'No healthy backends available',
         backends: status_info
       }.to_json]]
    end
  end
end
