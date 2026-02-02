# frozen_string_literal: true

require 'oj'
require 'securerandom'
require 'concurrent'

module Cache
  class TaggedCache
    VERSION_PREFIX = "tag_version".freeze

    def initialize(redis_pool)
      @redis_pool = redis_pool
      @hits = Concurrent::AtomicFixnum.new(0)
      @misses = Concurrent::AtomicFixnum.new(0)
    end

    def fetch(key, tags: [], expires_in: 3600, &block)
      # Check if cached value exists and is valid
      cached = read(key, tags)
      if cached
        @hits.increment
        return cached
      end

      # Cache miss — generate new value
      @misses.increment
      value = yield

      # Write with tags
      write(key, value, tags: tags, expires_in: expires_in)

      value
    end

    def write(key, value, tags: [], expires_in: 3600)
      # Get current versions for all tags
      tag_versions = get_tag_versions(tags)

      # Store value with tag versions
      data = {
        value: value,
        tag_versions: tag_versions,
        stored_at: Time.now.to_f
      }

      @redis_pool.with do |redis|
        redis.setex(
          cache_key(key),
          expires_in,
          Oj.dump(data)
        )
      end
    end

    def read(key, expected_tags = [])
      @redis_pool.with do |redis|
        raw = redis.get(cache_key(key))
        return nil unless raw

        data = Oj.load(raw, symbol_keys: true)

        # Validate tag versions
        if expected_tags.any?
          current_versions = get_tag_versions(expected_tags)
          stored_versions = data[:tag_versions] || {}

          expected_tags.each do |tag|
            stored_version = stored_versions[tag.to_s] || stored_versions[tag.to_sym]
            current_version = current_versions[tag]

            if stored_version != current_version
              # Tag was invalidated — cache is stale
              redis.del(cache_key(key))
              return nil
            end
          end
        end

        data[:value]
      end
    end

    def invalidate_tag(tag)
      # Simply increment tag version
      # All cached values with old version become invalid
      @redis_pool.with do |redis|
        redis.incr(tag_key(tag))
      end
    end

    def invalidate_tags(*tags)
      @redis_pool.with do |redis|
        redis.pipelined do |pipe|
          tags.flatten.each { |tag| pipe.incr(tag_key(tag)) }
        end
      end
    end

    def delete(key)
      @redis_pool.with do |redis|
        redis.del(cache_key(key))
      end
    end

    # Получить текущие версии тегов
    def tag_versions(tags)
      get_tag_versions(tags)
    end

    def stats
      total = @hits.value + @misses.value
      {
        hits: @hits.value,
        misses: @misses.value,
        hit_rate: total > 0 ? (@hits.value.to_f / total * 100).round(2) : 0
      }
    end

    private

    def cache_key(key)
      "tagged_cache:#{key}"
    end

    def tag_key(tag)
      "#{VERSION_PREFIX}:#{tag}"
    end

    def get_tag_versions(tags)
      return {} if tags.empty?

      @redis_pool.with do |redis|
        keys = tags.map { |t| tag_key(t) }
        values = redis.mget(*keys)

        tags.zip(values).to_h { |tag, version| [tag, version || "0"] }
      end
    end
  end

  module Middleware
    class TaggedCacheMiddleware
      def initialize(app, cache:)
        @app = app
        @cache = cache
      end

      def call(env)
        # Определяем теги для этого запроса
        tags = extract_tags(env)

        # Для GET запросов — пробуем кэш
        if env['REQUEST_METHOD'] == 'GET' && cacheable?(env)
          cache_key = build_cache_key(env)

          cached = @cache.fetch(cache_key, tags: tags, expires_in: 300) do
            status, headers, body = @app.call(env)

            # Кэшируем только успешные ответы
            if status == 200
              body_content = extract_body(body)
              { status: status, headers: headers.to_h, body: body_content }
            else
              # Не кэшируем, но возвращаем
              return [status, headers, body]
            end
          end

          [cached[:status], cached[:headers], [cached[:body]]]
        else
          # Не кэшируемый запрос
          @app.call(env)
        end
      end

      private

      def extract_tags(env)
        tags = []

        path = env['PATH_INFO']

        # Извлекаем теги из пути
        if path.match?(%r{/api/users})
          tags << 'users'
        end

        if path.match?(%r{/api/orders})
          tags << 'orders'
        end

        if match = path.match(%r{/api/users/(\d+)})
          tags << "user:#{match[1]}"
        end

        tags
      end

      def cacheable?(env)
        # Не кэшируем с Authorization header (персональные данные)
        return false if env['HTTP_AUTHORIZATION']

        # Кэшируем только API endpoints
        env['PATH_INFO'].start_with?('/api/')
      end

      def build_cache_key(env)
        [
          env['REQUEST_METHOD'],
          env['PATH_INFO'],
          env['QUERY_STRING']
        ].join(':')
      end

      def extract_body(body)
        content = ''
        body.each { |chunk| content << chunk }
        body.close if body.respond_to?(:close)
        content
      end
    end
  end
end
