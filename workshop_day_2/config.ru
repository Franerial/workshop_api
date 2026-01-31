require 'dotenv/load'
require 'rack/attack'
require_relative 'app'
require_relative 'config/initializers/rack_attack'
require_relative 'lib/middleware/jwt_auth'

scope_requirements = {
  'GET /api/orders' => 'read:orders',
  'POST /api/orders' => 'write:orders'
}

jwt_service = Auth::JwtService.new(
  redis: Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')),
  access_secret: ENV.fetch('JWT_ACCESS_SECRET'),
  refresh_secret: ENV.fetch('JWT_REFRESH_SECRET')
)

# Middleware стэк
use Rack::Attack

# JWT Auth middleware (применяется только к защищённым эндпоинтам)
# Для Sinatra приложения аутентификация реализована через helpers
# Но можем добавить middleware для автоматической проверки токенов

use Rack::Logger
use Rack::CommonLogger

# Инициализация тестовых данных
ApiGatewayApp.seed_data!

use Middleware::JwtAuth, 
    jwt_service: jwt_service, 
    exclude_paths: ['/health', '/api/auth/login', '/api/auth/refresh'],
    required_scopes: scope_requirements

run ApiGatewayApp
