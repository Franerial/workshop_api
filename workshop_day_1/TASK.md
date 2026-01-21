# Практическое задание: Интеграция Semian Circuit Breaker

## Цель задания

Заменить самописную реализацию Circuit Breaker на production-ready библиотеку **Semian** от Shopify. Убедиться, что circuit breaker корректно отрабатывает при сбоях backend-сервисов.

## Контекст

Сейчас в проекте используется упрощенная реализация Circuit Breaker в `lib/gateway/middleware/circuit_breaker.rb`, которая отслеживает состояние через хэш:

```ruby
@circuit_states = {
  'users_service' => {
    state: :closed,
    failures: 0,
    last_failure_time: nil
  }
}
```

**Недостатки текущей реализации:**
- Не интегрируется с Net::HTTP на уровне транспорта
- Требует ручной обработки исключений в каждом месте
- Нет bulkhead (ограничения concurrent запросов)
- Состояние не сохраняется между перезапусками
- Не поддерживает адаптивные timeout'ы

**Semian** решает все эти проблемы, оборачивая HTTP-клиент на уровне адаптера.

## Что такое Semian?

Semian — это gem от Shopify для реализации паттернов устойчивости (resilience patterns):
- Circuit Breaker
- Bulkhead (ограничение concurrent connections)
- Интеграция с Net::HTTP, Redis, MySQL, PostgreSQL

**GitHub:** https://github.com/Shopify/semian

**Основные возможности:**
- Автоматическое оборачивание HTTP-запросов
- Thread-safe реализация
- Настройка per-host (разные параметры для разных сервисов)
- Мониторинг состояния circuit'ов

## Задание

### Шаг 1: Форк репозитория

1. Сделайте fork этого репозитория в свой GitHub аккаунт
2. Склонируйте форк локально:

```bash
git clone https://github.com/YOUR_USERNAME/worshop_day_1.git
cd worshop_day_1
```

3. Создайте новую ветку для работы:

```bash
git checkout -b feature/semian-integration-<username>
```

### Шаг 2: Установка Semian

Добавьте в `Gemfile`:

```ruby
gem 'semian'
```

Установите зависимости:

```bash
bundle install
```

**Важно:** Semian использует C-расширения, поэтому нужны build tools:
- macOS: `xcode-select --install`
- Ubuntu/Debian: `apt-get install build-essential`

### Шаг 3: Замена Circuit Breaker

#### 3.1. Удалите или закомментируйте текущую реализацию

В `lib/gateway/middleware/circuit_breaker.rb` — весь код самописного circuit breaker.

#### 3.2. Интегрируйте Semian

Semian работает на уровне транспорта. Так как Gateway использует Faraday → Net::HTTP, нужно настроить Semian для Net::HTTP.

Создайте новый файл `lib/gateway/middleware/semian_circuit_breaker.rb`:

```ruby
require 'semian'
require 'semian/net_http'

module Gateway
  module Middleware
    class SemianCircuitBreaker
      def initialize(app)
        @app = app
        configure_semian
      end

      def call(env)
        begin
          @app.call(env)
        rescue Semian::OpenCircuitError => e
          # Circuit открыт — сервис недоступен
          handle_open_circuit(env, e)
        end
      end

      private

      def configure_semian
        # Конфигурация Semian для Net::HTTP
        Semian::NetHTTP.semian_configuration = proc do |host, port|
          # TODO: Настроить параметры circuit breaker
          # См. документацию: https://github.com/Shopify/semian#nethttp-adapter

          {
            name: circuit_name_for(host, port),
            circuit_breaker: true,
            success_threshold: 2,      # Сколько успешных запросов для закрытия
            error_threshold: 3,        # Сколько ошибок для открытия
            error_timeout: 10,         # Секунд в OPEN state
            bulkhead: true,
            tickets: 20                # Макс. concurrent запросов
          }
        end
      end

      def circuit_name_for(host, port)
        # TODO: Реализовать маппинг host:port → имя сервиса
        # Например: localhost:3001 → users_service
      end

      def handle_open_circuit(env, error)
        # TODO: Вернуть 503 с информацией о circuit
      end
    end
  end
end
```

#### 3.3. Обновите config.ru

Замените старый CircuitBreaker на новый:

```ruby
# Было:
use Gateway::Middleware::CircuitBreaker

# Стало:
use Gateway::Middleware::SemianCircuitBreaker
```

### Шаг 4: Настройка параметров

Настройте параметры circuit breaker для каждого backend'а:

| Backend | Error Threshold | Error Timeout | Tickets |
|---------|-----------------|---------------|---------|
| Users Service (3001, 3011) | 3 | 10s | 20 |
| Orders Service (3002) | 5 | 15s | 10 |
| Products Service (3003, 3013) | 3 | 10s | 15 |

**Почему разные параметры?**
- Orders Service — критичный, даем больше попыток (5 errors)
- Products — менее критичный, меньше concurrent соединений

### Шаг 5: Тестирование

#### 5.1. Запустите систему

```bash
# Запустить backend'ы
PORT=3001 bundle exec rackup mock_backend_with_id.ru -p 3001 &
PORT=3011 bundle exec rackup mock_backend_with_id.ru -p 3011 &
PORT=3002 bundle exec rackup mock_backend_with_id.ru -p 3002 &

# Запустить Gateway
bundle exec rackup config.ru -p 4000
```

#### 5.2. Проверьте, что все работает

```bash
# Базовый запрос
curl http://localhost:4000/api/users/1

# Должен вернуть успешный ответ с данными пользователя
```

#### 5.3. Симуляция сбоя backend'а

**Вариант 1: Остановить backend**

```bash
# Остановить backend на порту 3001
kill $(lsof -ti:3001)

# Сделать серию запросов
for i in {1..10}; do
  echo "Request $i:"
  curl -s http://localhost:4000/api/users/1 | jq -r 'if .success then "✓ SUCCESS" else "✗ " + .error.code end'
  sleep 0.5
done
```

**Ожидаемое поведение:**
1. Первые 1-3 запроса: `✗ bad_gateway` (circuit еще закрыт, получаем timeout)
2. После достижения `error_threshold`: `✗ service_unavailable` (circuit открылся!)
3. Дальнейшие запросы: либо `✓ SUCCESS` (идут на здоровый backend 3011), либо мгновенный `✗ service_unavailable`

**Вариант 2: Искусственный неправильный URL**

Временно измените в Router один backend на несуществующий:

```ruby
backends: ['http://localhost:9999', 'http://localhost:3011']
```

Перезапустите Gateway и повторите тесты.

#### 5.4. Проверка восстановления

Запустите backend снова:

```bash
PORT=3001 bundle exec rackup mock_backend_with_id.ru -p 3001 &
```

Подождите `error_timeout` секунд (10s по умолчанию) и сделайте запросы:

```bash
# Через ~10 секунд circuit перейдет в HALF-OPEN
# Один успешный запрос закроет circuit (success_threshold: 2)
for i in {1..5}; do
  curl -s http://localhost:4000/api/users/1 | jq -r '.success'
  sleep 2
done
```

**Ожидаемое поведение:**
- Circuit должен закрыться после 2 успешных запросов
- Все последующие запросы идут нормально

### Шаг 6: Добавьте мониторинг состояния Circuit

Добавьте endpoint для просмотра состояния circuit'ов:

```ruby
# lib/gateway/health_endpoint.rb

when '/health/circuits'
  circuits_status_response

# ...

def circuits_status_response
  circuits = {}

  # Получить информацию о всех circuit'ах из Semian
  Semian.resources.each do |name, resource|
    if resource.circuit_breaker
      circuits[name] = {
        state: circuit_state_name(resource.circuit_breaker),
        error_count: resource.circuit_breaker.error_count,
        success_count: resource.circuit_breaker.success_count
      }
    end
  end

  [200, {'Content-Type' => 'application/json'}, [circuits.to_json]]
end

def circuit_state_name(circuit)
  if circuit.open?
    'open'
  elsif circuit.half_open?
    'half_open'
  else
    'closed'
  end
end
```

Проверьте:

```bash
curl http://localhost:4000/health/circuits | jq .
```

### Шаг 7: Документация

Обновите `README.md`:

1. Добавьте секцию "Circuit Breaker с Semian"
2. Опишите конфигурацию параметров
3. Добавьте примеры тестирования

### Шаг 8: Pull Request

1. Закоммитьте изменения:

```bash
git add .
git commit -m "Replace custom circuit breaker with Semian

- Added Semian gem integration for Net::HTTP
- Configured per-service circuit breaker parameters
- Added /health/circuits endpoint for monitoring
- Updated documentation with Semian usage examples
- Tested circuit breaker behavior with backend failures"
```

2. Запушьте в свой fork:

```bash
git push origin feature/semian-integration-<username>
```

3. Создайте Pull Request на GitHub:
   - Откройте свой fork на GitHub
   - Нажмите "Pull Request"
   - Заполните описание (см. шаблон ниже)

## Критерии приемки

✅ **Обязательно:**

1. Semian корректно интегрирован (Gemfile, require)
2. Circuit breaker открывается после N ошибок (`error_threshold`)
3. Circuit автоматически переходит в HALF-OPEN после `error_timeout`
4. Circuit закрывается после успешных запросов
5. Добавлен endpoint `/health/circuits` для мониторинга
6. Код протестирован с реальными сбоями backend'ов
7. Обновлена документация

✅ **Дополнительно (по желанию):**

- Настроены разные параметры для разных сервисов
- Добавлены метрики Semian в `/metrics` endpoint (Prometheus format)
- Реализован graceful shutdown с ожиданием завершения запросов
- Добавлены unit-тесты для SemianCircuitBreaker middleware
- Интегрирован Semian для других адаптеров (Redis, MySQL)

## Шаблон описания Pull Request

```markdown
## Описание изменений

Заменил самописную реализацию Circuit Breaker на Semian от Shopify.

## Что сделано

- [ ] Добавлен `semian` gem в Gemfile
- [ ] Создан `SemianCircuitBreaker` middleware
- [ ] Настроены параметры circuit breaker для каждого сервиса
- [ ] Удален старый `CircuitBreaker` middleware
- [ ] Добавлен endpoint `/health/circuits`
- [ ] Протестирован с остановкой backend'ов
- [ ] Обновлена документация

## Результаты тестирования

### Circuit открывается при сбоях

```
Request 1: ✗ bad_gateway
Request 2: ✗ bad_gateway
Request 3: ✗ bad_gateway
Request 4: ✗ service_unavailable  ← Circuit открылся!
Request 5: ✗ service_unavailable
```

### Circuit закрывается после восстановления

```
Request 1: ✓ SUCCESS
Request 2: ✓ SUCCESS  ← Circuit закрылся после 2 успехов
Request 3: ✓ SUCCESS
```

### Состояние circuit'ов

```bash
$ curl http://localhost:4000/health/circuits
{
  "users_service": {
    "state": "closed",
    "error_count": 0,
    "success_count": 10
  },
  "orders_service": {
    "state": "open",
    "error_count": 5,
    "success_count": 0
  }
}
```

## Конфигурация

| Сервис | Error Threshold | Error Timeout | Bulkhead Tickets |
|--------|-----------------|---------------|------------------|
| Users  | 3 | 10s | 20 |
| Orders | 5 | 15s | 10 |
| Products | 3 | 10s | 15 |

## Скриншоты (опционально)

[Приложите скриншоты логов или тестов]
```

## Отправка задания

**Формат ответа:** Ссылка на Pull Request в вашем форке репозитория.

Пример:
```
https://github.com/YOUR_USERNAME/worshop_day_1/pull/1
```

## Полезные ссылки

- [Semian GitHub](https://github.com/Shopify/semian)
- [Semian Wiki](https://github.com/Shopify/semian/wiki)
- [Circuit Breaker Pattern (Martin Fowler)](https://martinfowler.com/bliki/CircuitBreaker.html)
- [Shopify Engineering Blog: Resilience](https://shopify.engineering/circuit-breaker-misconfigured)

## Часто встречающиеся проблемы

### 1. LoadError: cannot load such file -- semian

**Причина:** Не установлены зависимости.

**Решение:**
```bash
bundle install
```

### 2. Circuit не открывается

**Причина:** Timeout слишком большой или error_threshold не достигнут.

**Решение:**
- Уменьшите `error_threshold` до 2-3
- Уменьшите timeout в Faraday до 2-3 секунд
- Убедитесь, что делаете достаточно запросов подряд

### 3. Semian::OpenCircuitError не перехватывается

**Причина:** Исключение бросается на уровне Net::HTTP, а не в middleware.

**Решение:**
- Оборачивайте вызов `@app.call(env)` в `begin/rescue`
- Убедитесь, что `require 'semian/net_http'` выполнено ДО создания Faraday connections

### 4. Circuit открывается для всех backends сразу

**Причина:** Все backend'ы используют одно имя circuit'а.

**Решение:**
- Проверьте `circuit_name_for` — должны быть уникальные имена
- Используйте `"#{host}_#{port}"` или маппинг на service name

### 5. Bulkhead не работает

**Причина:** Параметр `tickets` настроен неправильно.

**Решение:**
```ruby
{
  bulkhead: true,
  tickets: 20  # Должно быть > 0
}
```

## Дополнительное задание (advanced)

### 1. Адаптивные timeout'ы

Реализуйте механизм, который увеличивает timeout при высокой нагрузке:

```ruby
def adaptive_timeout(backend)
  base_timeout = 5
  current_load = @connection_counts[backend]

  base_timeout * (1 + current_load / 20.0)
end
```

### 2. Мониторинг в Prometheus

Экспортируйте метрики Semian:

```ruby
# GET /metrics
def metrics_response
  metrics = []

  Semian.resources.each do |name, resource|
    if resource.circuit_breaker
      state = resource.circuit_breaker.open? ? 1 : 0
      metrics << "semian_circuit_open{service=\"#{name}\"} #{state}"
      metrics << "semian_circuit_errors{service=\"#{name}\"} #{resource.circuit_breaker.error_count}"
    end
  end

  [200, {'Content-Type' => 'text/plain'}, [metrics.join("\n")]]
end
```

### 3. Graceful shutdown

Реализуйте корректное завершение работы Gateway:

```ruby
# config.ru
at_exit do
  puts "Shutting down gracefully..."

  # Ждем завершения активных запросов
  timeout = 30
  start = Time.now

  loop do
    active = total_active_connections
    break if active.zero?
    break if Time.now - start > timeout

    puts "Waiting for #{active} connections to finish..."
    sleep 1
  end

  puts "Shutdown complete"
end
```

## Вопросы и помощь

Если возникли вопросы:
1. Проверьте [WIKI.md](WIKI.md) — там подробная документация
2. Изучите примеры в [demo/](demo/)
3. Посмотрите issue в Semian GitHub

Удачи! 🚀
