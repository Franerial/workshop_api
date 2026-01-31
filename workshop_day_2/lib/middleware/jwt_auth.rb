module Middleware
  class JwtAuth
    def initialize(app, jwt_service:, exclude_paths: [], required_scopes: [])
      @app = app
      @jwt_service = jwt_service
      @exclude_paths = exclude_paths
      @required_scopes = required_scopes
    end

    def call(env)
      request = Rack::Request.new(env)
      path = request.path
      method = request.request_method

      # Пропускаем публичные endpoints
      return @app.call(env) if excluded?(path)

      token = extract_token(env)

      return unauthorized('Missing authorization header') unless token

      begin
        payload = @jwt_service.verify_access_token(token)

        user_scopes = payload['scopes'] || []
        env['api.user_id'] = payload['user_id']
        env['api.scopes'] = payload['scopes'] || []

        lookup_key = "#{method} #{path}"
        required_scope = @required_scopes[lookup_key]

        if required_scope && !user_scopes.include?(required_scope)
          return forbidden(required_scope, user_scopes)
        end

        @app.call(env)
      rescue Auth::JwtService::ExpiredTokenError
        unauthorized('Token has expired', error_code: 'token_expired')
      rescue Auth::JwtService::InvalidTokenError => e
        unauthorized(e.message, error_code: 'invalid_token')
      end
    end

    private

    def excluded?(path)
      @exclude_paths.any? { |pattern| path.start_with?(pattern) }
    end

    def extract_token(env)
      auth_header = env['HTTP_AUTHORIZATION']
      return nil unless auth_header

      # Поддержка формата "Bearer TOKEN"
      if auth_header.start_with?('Bearer ')
        auth_header.sub('Bearer ', '')
      else
        auth_header
      end
    end

    def unauthorized(message, error_code: 'unauthorized')
      [
        401,
        {
          'Content-Type' => 'application/json',
          'WWW-Authenticate' => 'Bearer realm="API"'
        },
        [{ error: error_code, message: message }.to_json]
      ]
    end

    def forbidden(required, actual)
      [
        403,
        { 'Content-Type' => 'application/json' },
        [{
          error: 'insufficient_scope',
          required: required,
          your_scopes: actual
        }.to_json]
      ]
    end
  end
end
