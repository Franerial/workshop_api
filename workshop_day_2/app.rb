require 'sinatra'
require 'sinatra/json'
require 'redis'
require 'connection_pool'
require 'bcrypt'
require 'dotenv/load'
require 'json'

# Загружаем модели и сервисы
require_relative 'lib/models'
require_relative 'lib/auth/jwt_service'
require_relative 'lib/auth/api_key_service'
require_relative 'lib/rate_limiter/tiered_limiter'
require_relative 'lib/middleware/jwt_auth'

class ApiGatewayApp < Sinatra::Base
  configure do
    set :show_exceptions, false
    set :raise_errors, false
    set :dump_errors, true

    # Redis подключения
    redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')

    # Глобальный Redis для Rack::Attack
    $redis = Redis.new(url: redis_url)

    # Redis connection pool для rate limiter (требует пулирования)
    pool = ConnectionPool.new(size: 10, timeout: 5) do
      Redis.new(url: redis_url)
    end
    set :redis_pool, pool

    # Сервисы
    set :jwt_service, Auth::JwtService.new(
      redis: Redis.new(url: redis_url),
      access_secret: ENV.fetch('JWT_ACCESS_SECRET'),
      refresh_secret: ENV.fetch('JWT_REFRESH_SECRET')
    )

    set :api_key_service, Auth::ApiKeyService.new(
      redis: Redis.new(url: redis_url)
    )

    set :rate_limiter, RateLimiter::TieredLimiter.new(
      redis_pool: pool
    )

  end

  # Seed данных для демонстрации
  def self.seed_data!
    return if User.all.any?

    # Создаём пользователей с разными тирами
    User.create!(
      email: 'free@example.com',
      password_hash: BCrypt::Password.create('password'),
      scopes: ['read', 'write'],
      tier: 'free'
    )

    User.create!(
      email: 'startup@example.com',
      password_hash: BCrypt::Password.create('password'),
      scopes: ['read', 'write'],
      tier: 'startup'
    )

    User.create!(
      email: 'business@example.com',
      password_hash: BCrypt::Password.create('password'),
      scopes: ['read:orders', 'write:orders', 'admin'],
      tier: 'business'
    )

    User.create!(
      email: 'enterprise@example.com',
      password_hash: BCrypt::Password.create('password'),
      scopes: ['read', 'write', 'admin', 'analytics'],
      tier: 'enterprise'
    )

    # Создаём клиентов для API keys
    ['free', 'startup', 'business', 'enterprise'].each do |tier|
      Client.create!(
        name: "#{tier.capitalize} Client",
        tier: tier
      )
    end

    puts "✅ Seed data created!"
    puts "   Users: #{User.all.map(&:email).join(', ')}"
    puts "   Clients: #{Client.all.map(&:name).join(', ')}"
  end

  # Helper методы
  helpers do
    def current_user_id
      request.env['api.user_id']
    end

    def current_user
      @current_user ||= User.find(current_user_id) if current_user_id
    end

    def json_params
      @json_params ||= begin
        request.body.rewind
        JSON.parse(request.body.read)
      rescue JSON::ParserError
        {}
      end
    end

    def authenticate_api_key!
      api_key = request.env['HTTP_X_API_KEY']
      return error(401, 'Missing API key') unless api_key

      @api_key_record = settings.api_key_service.validate(api_key)
      return error(401, 'Invalid API key') unless @api_key_record

      @current_client = @api_key_record.client
    end

    def check_rate_limits!
      return unless @current_client

      result = settings.rate_limiter.check_all_limits(@current_client)

      # Добавляем headers в ответ
      headers.merge!(settings.rate_limiter.build_headers(
        result,
        RateLimiter::TieredLimiter::TIERS[@current_client.tier.to_sym]
      ))

      unless result[:allowed]
        error(429, "Rate limit exceeded: #{result[:reason]}", extra: {
          tier: result[:tier],
          checks: result[:checks]
        })
      end
    end

    def release_concurrent_slot!
      return unless @current_client
      settings.rate_limiter.release_concurrent(@current_client)
    end

    def error(status, message, extra: {})
      halt status, json({ error: message }.merge(extra))
    end
  end

  # Error handlers
  error JSON::ParserError do
    status 400
    json error: 'Invalid JSON'
  end

  error do
    status 500
    json error: 'Internal server error'
  end

  ### Public Endpoints ###

  get '/health' do
    json status: 'ok', redis: $redis.ping
  end

  get '/' do
    json(
      message: 'API Gateway Workshop - Day 2',
      endpoints: {
        health: 'GET /health',
        auth: {
          login: 'POST /api/auth/login',
          refresh: 'POST /api/auth/refresh',
          logout: 'POST /api/auth/logout'
        },
        api_keys: {
          generate: 'POST /api/keys/generate',
          rotate: 'POST /api/keys/rotate/:client_id',
          revoke: 'POST /api/keys/revoke/:key_id',
          list: 'GET /api/keys/list/:client_id'
        },
        orders: {
          list: 'GET /api/orders',
          create: 'POST /api/orders'
        }
      }
    )
  end

  ### Auth Endpoints ###

  post '/api/auth/login' do
    email = json_params['email']
    password = json_params['password']

    return error(400, 'Email and password required') unless email && password

    user = User.find_by_email(email)
    return error(401, 'Invalid credentials') unless user

    unless BCrypt::Password.new(user.password_hash) == password
      return error(401, 'Invalid credentials')
    end

    tokens = settings.jwt_service.generate_tokens(user)

    json(
      message: 'Login successful',
      user: { id: user.id, email: user.email, tier: user.tier },
      tokens: tokens
    )
  end

  post '/api/auth/refresh' do
    refresh_token = json_params['refresh_token']
    return error(400, 'Refresh token required') unless refresh_token

    begin
      tokens = settings.jwt_service.refresh(refresh_token)
      json(
        message: 'Tokens refreshed',
        tokens: tokens
      )
    rescue Auth::JwtService::InvalidTokenError => e
      error(401, e.message)
    rescue Auth::JwtService::ExpiredTokenError => e
      error(401, e.message)
    end
  end

  post '/api/auth/logout' do
    # Для JWT обычно logout на клиенте (удаление токена)
    # Но можем отозвать все refresh tokens
    if current_user_id
      settings.jwt_service.revoke_all_refresh_tokens(current_user_id)
      json message: 'Logged out successfully'
    else
      error(401, 'Not authenticated')
    end
  end

  ### API Key Management ###

  post '/api/keys/generate' do
    client_id = json_params['client_id']
    return error(400, 'Client ID required') unless client_id

    client = Client.find(client_id.to_i)
    return error(404, 'Client not found') unless client

    result = settings.api_key_service.generate(client)

    json(
      message: 'API key generated',
      api_key: result
    )
  end

  post '/api/keys/rotate/:client_id' do
    client = Client.find(params[:client_id].to_i)
    return error(404, 'Client not found') unless client

    result = settings.api_key_service.rotate(client)

    json(
      message: 'API key rotated',
      rotation: result
    )
  end

  post '/api/keys/revoke/:key_id' do
    reason = json_params['reason'] || 'Manual revocation'

    api_key = ApiKey.where(id: params[:key_id].to_i).first
    return error(404, 'API key not found') unless api_key

    result = settings.api_key_service.revoke(api_key, reason: reason)

    json(
      message: 'API key revoked',
      result: result
    )
  end

  get '/api/keys/list/:client_id' do
    client = Client.find(params[:client_id].to_i)
    return error(404, 'Client not found') unless client

    keys = settings.api_key_service.list_keys(client)

    json(
      client_id: client.id,
      client_name: client.name,
      tier: client.tier,
      api_keys: keys
    )
  end

  ### Protected API Endpoints (с rate limiting) ###

  get '/api/orders' do
    # using Middleware::JwtAuth instead
    # authenticate_api_key!
    # check_rate_limits!

    # Симуляция работы
    orders = [
      { id: 1, product: 'Widget', quantity: 10, status: 'pending' },
      { id: 2, product: 'Gadget', quantity: 5, status: 'shipped' },
      { id: 3, product: 'Doohickey', quantity: 3, status: 'delivered' }
    ]

    # release_concurrent_slot!

    json(
      user_email: current_user&.email,
      orders: orders
    )
  end

  post '/api/orders' do
    # using Middleware::JwtAuth instead
    # authenticate_api_key!
    # check_rate_limits!

    order_data = json_params

    # Simulation of order creation
    order = {
      id: rand(1000..9999),
      product: order_data['product'],
      quantity: order_data['quantity'],
      status: 'pending',
      created_at: Time.now.to_i,
      created_by_user_id: request.env['api.user_id'] 
    }

    status 201
    json(
      message: 'Order created',
      order: order
    )
  end

  # Демо endpoint для тестирования разных тиров
  get '/api/demo/rate-limit-test' do
    authenticate_api_key!
    check_rate_limits!

    release_concurrent_slot!

    json(
      message: "Request successful for #{@current_client.tier} tier",
      request_number: rand(1..100),
      timestamp: Time.now.to_i
    )
  end
end
