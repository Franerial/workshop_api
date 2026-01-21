# API Gateway - Документация

## Содержание

- [Обзор](#обзор)
- [Архитектура](#архитектура)
- [Компоненты](#компоненты)
- [Паттерны устойчивости](#паттерны-устойчивости)
- [Middleware Stack](#middleware-stack)
- [Конфигурация](#конфигурация)
- [Примеры использования](#примеры-использования)

## Обзор

Это учебная реализация API Gateway на Ruby/Rack, демонстрирующая ключевые паттерны построения устойчивых микросервисных систем.

### Что такое API Gateway?

API Gateway — это единая точка входа для всех клиентских запросов в бэкэенд которая потом распределяет их по микросервисам. Он выполняет функции:

- **Маршрутизация** — направляет запросы в нужные backend-сервисы
- **Агрегация** — собирает данные из нескольких сервисов
- **Трансформация** — модифицирует запросы и ответы
- **Устойчивость** — защищает от каскадных сбоев через Circuit Breaker
- **Балансировка** — распределяет нагрузку между репликами сервисов
- **Мониторинг** — добавляет request ID, трейсинг, метрики

### Когда нужен API Gateway?

✅ **Нужен:**
- 5+ микросервисов с общими требованиями (auth, rate limiting)
- Необходима агрегация данных для мобильных клиентов
- Разные клиенты нуждаются в разных представлениях данных
- Нужно скрыть внутреннюю архитектуру от внешних потребителей

❌ **Не нужен:**
- Монолитное приложение (используйте Rack middleware)
- 2-3 микросервиса (достаточно Nginx reverse proxy)
- Нет общих cross-cutting concerns

## Архитектура

```
┌─────────────┐
│   Client    │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────────┐
│         API Gateway (Port 4000)      │
│                                      │
│  ┌────────────────────────────────┐ │
│  │  Health Endpoint               │ │
│  └────────────────────────────────┘ │
│  ┌────────────────────────────────┐ │
│  │  Request Transformer           │ │
│  │  (Request ID, Trace ID)        │ │
│  └────────────────────────────────┘ │
│  ┌────────────────────────────────┐ │
│  │  Response Transformer          │ │
│  │  (Wrap in standard format)     │ │
│  └────────────────────────────────┘ │
│  ┌────────────────────────────────┐ │
│  │  Router + Load Balancer        │ │
│  │  (Path-based routing)          │ │
│  └────────────────────────────────┘ │
│  ┌────────────────────────────────┐ │
│  │  Circuit Breaker               │ │
│  │  (Failure detection)           │ │
│  └────────────────────────────────┘ │
│  ┌────────────────────────────────┐ │
│  │  Proxy                         │ │
│  │  (HTTP forwarding)             │ │
│  └────────────────────────────────┘ │
└──────────────┬──────────────────────┘
               │
       ┌───────┴────────┐
       ▼                ▼
┌─────────────┐  ┌─────────────┐
│  Users      │  │  Orders     │
│  Service    │  │  Service    │
│  :3001      │  │  :3002      │
│  :3011      │  │             │
└─────────────┘  └─────────────┘
       ▼                ▼
┌─────────────┐  ┌─────────────┐
│  Products   │  │  Health     │
│  Service    │  │  Checker    │
│  :3003      │  │  (Background)│
│  :3013      │  │             │
└─────────────┘  └─────────────┘
```

## Компоненты

### 1. Router (`lib/gateway/router.rb`)

Отвечает за маршрутизацию запросов на основе URL path.

**Основные функции:**
- Сопоставление URL с backend-сервисами через регулярные выражения
- Path rewriting (убирает префиксы типа `/api`)
- Интеграция с Load Balancer для выбора конкретного backend
- Обработка случаев, когда нет здоровых backend'ов

**Конфигурация маршрутов:**

```ruby
ROUTES = {
  %r{^/api/users} => {
    backends: ['http://localhost:3001', 'http://localhost:3011'],
    strip_prefix: '/api'
  },
  %r{^/api/orders} => {
    backends: ['http://localhost:3002'],
    strip_prefix: '/api'
  }
}
```

**Как работает:**

1. Получает запрос с `PATH_INFO = /api/users/123`
2. Находит подходящий маршрут через regex (`%r{^/api/users}`)
3. Запрашивает у Load Balancer здоровый backend
4. Убирает префикс `/api`, путь становится `/users/123`
5. Сохраняет выбранный backend в `env['gateway.backend']`
6. Передает управление следующему middleware

### 2. Load Balancer (`lib/gateway/load_balancer.rb`)

Распределяет нагрузку между репликами backend-сервисов.

**Стратегии балансировки:**

1. **Round Robin** (по умолчанию)
   - Циклическое переключение между backend'ами
   - Использует атомарный счетчик для thread-safety

2. **Least Connections**
   - Выбирает backend с наименьшим количеством активных соединений
   - Отслеживает `connection_counts` для каждого backend

3. **Random**
   - Случайный выбор backend'а

**Алгоритм работы:**

```ruby
def select_backend(backends)
  # 1. Фильтруем только здоровые backends
  healthy = backends.select { |b| @health_checker.healthy?(b) }

  # 2. Если нет здоровых — возвращаем nil
  return nil if healthy.empty?

  # 3. Если только один — возвращаем его
  return healthy.first if healthy.size == 1

  # 4. Применяем стратегию балансировки
  case @strategy
  when :round_robin
    index = @round_robin_index.increment % healthy.size
    healthy[index]
  when :least_connections
    healthy.min_by { |b| @connection_counts[b] }
  end
end
```

**Важно:** Load Balancer автоматически исключает unhealthy backends из ротации.

### 3. Health Checker (`lib/gateway/health_checker.rb`)

Фоновый процесс, проверяющий доступность backend-сервисов.

**Параметры:**

- `HEALTH_CHECK_INTERVAL = 10` секунд между проверками
- `HEALTH_CHECK_TIMEOUT = 2` секунды на один запрос
- `UNHEALTHY_THRESHOLD = 3` — сколько неудач до пометки unhealthy
- `HEALTHY_THRESHOLD = 2` — сколько успехов до пометки healthy

**Состояния backend:**

- `:healthy` — сервис отвечает нормально
- `:unhealthy` — сервис недоступен

**Алгоритм:**

```
┌─────────────┐
│   Healthy   │ ◄───────────────┐
└──────┬──────┘                 │
       │                        │
       │ 3 failures       2 successes
       │                        │
       ▼                        │
┌─────────────┐                 │
│  Unhealthy  │─────────────────┘
└─────────────┘
```

**Как работает:**

1. При старте запускает фоновый Thread
2. Каждые 10 секунд делает GET `/health` ко всем backend'ам
3. Если ответ успешен (2xx) — увеличивает `success_counts`
4. Если ошибка — увеличивает `failure_counts`
5. При достижении порогов меняет статус backend'а

**Thread-safety:** Использует `Concurrent::Hash` для безопасной работы из нескольких потоков.

### 4. Circuit Breaker (`lib/gateway/middleware/circuit_breaker.rb`)

Реализует паттерн Circuit Breaker для защиты от каскадных сбоев.

**Зачем нужен?**

Без Circuit Breaker при падении backend'а:
1. Запросы копятся в очереди
2. Threads блокируются на timeout'ах
3. Thread pool исчерпывается
4. Gateway перестает обрабатывать ВСЕ запросы

Circuit Breaker решает это, быстро отклоняя запросы к недоступному сервису.

**Состояния Circuit Breaker:**

```
        ┌─────────────────────────────────┐
        │                                 │
        │         CLOSED                  │
        │    (Normal operation)           │
        │                                 │
        └────────┬────────────────────────┘
                 │
                 │ error_threshold exceeded
                 │ (3 errors)
                 ▼
        ┌─────────────────────────────────┐
        │                                 │
        │          OPEN                   │
        │   (Fail fast, no requests)      │
        │                                 │
        └────────┬────────────────────────┘
                 │
                 │ after error_timeout
                 │ (10 seconds)
                 ▼
        ┌─────────────────────────────────┐
        │                                 │
        │       HALF-OPEN                 │
        │   (Testing with 1 request)      │
        │                                 │
        └─────┬───────────────────────┬───┘
              │                       │
      success │                       │ failure
              │                       │
              ▼                       ▼
           CLOSED                   OPEN
```

**Конфигурация:**

```ruby
CIRCUIT_CONFIG = {
  'localhost:3001' => {
    name: 'users_service',
    error_threshold: 3,    # После 3 ошибок → OPEN
    error_timeout: 10      # Ждем 10 сек перед retry
  }
}
```

**Текущая реализация:**

Сейчас используется **самописная** реализация, отслеживающая состояние через хэш:

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
- Требует ручной обработки исключений
- Нет bulkhead (ограничения concurrent запросов)
- Состояние не персистится между перезапусками

### 5. Proxy (`lib/gateway/proxy.rb`)

Выполняет фактическое проксирование HTTP-запросов к backend'ам.

**Основные задачи:**

1. **Извлечение данных из Rack env:**
   - HTTP метод (GET, POST, PUT, DELETE)
   - Path и query string
   - Request body (для POST/PUT/PATCH)
   - Headers

2. **Проксирование запроса:**
   - Использует Faraday для HTTP
   - Кэширует connections для переиспользования
   - Настраивает timeouts

3. **Обработка ответа:**
   - Преобразует Faraday response в Rack response
   - Удаляет hop-by-hop headers (`transfer-encoding`)
   - Обрабатывает ошибки (timeout, connection failed)

**Управление соединениями:**

```ruby
def connection_for(backend)
  @connections[backend] ||= Faraday.new(url: backend) do |f|
    f.options.timeout = 10           # Read timeout
    f.options.open_timeout = 5       # Connection timeout
    f.adapter :net_http
  end
end
```

Кэширует connection для каждого backend URL, что позволяет переиспользовать TCP-соединения (connection pooling).

**Обработка ошибок:**

- `Faraday::TimeoutError` → 504 Gateway Timeout
- `Faraday::ConnectionFailed` → 502 Bad Gateway
- Другие ошибки → 500 Internal Server Error

### 6. Request Transformer (`lib/gateway/middleware/request_transformer.rb`)

Добавляет метаданные к входящим запросам.

**Добавляемые заголовки:**

| Заголовок | Описание |
|-----------|----------|
| `X-Request-ID` | UUID для трейсинга конкретного запроса |
| `X-Trace-ID` | Hex-строка для distributed tracing |
| `X-Gateway-Timestamp` | Unix timestamp момента обработки |
| `X-Real-IP` | Реальный IP клиента |
| `X-Forwarded-For` | Цепочка прокси (для CDN/балансировщиков) |

**Зачем это нужно:**

1. **Debugging:** По Request-ID можно найти запрос во всех логах микросервисов
2. **Distributed Tracing:** Trace-ID позволяет построить полный путь запроса (Jaeger, Zipkin)
3. **Аудит:** Timestamp помогает измерять latency на каждом этапе
4. **Security:** X-Real-IP нужен для rate limiting, блокировок

**Пример:**

```
Входящий запрос:
  GET /api/users/1

Обогащается заголовками:
  X-Request-ID: 550e8400-e29b-41d4-a716-446655440000
  X-Trace-ID: 7f3d9e2a1c4b8f5e
  X-Gateway-Timestamp: 1705838400
  X-Real-IP: 192.168.1.100
  X-Forwarded-For: 203.0.113.1, 192.168.1.100
```

### 7. Response Transformer (`lib/gateway/middleware/response_transformer.rb`)

Стандартизирует формат всех ответов API.

**Структура успешного ответа:**

```json
{
  "success": true,
  "data": {
    "id": 1,
    "name": "User 1"
  },
  "meta": {
    "api_version": "2024.01",
    "request_id": "550e8400-e29b-41d4-a716-446655440000",
    "timestamp": "2026-01-21T10:23:44+01:00"
  }
}
```

**Структура ошибки:**

```json
{
  "success": false,
  "error": {
    "code": "not_found",
    "message": "Resource not found",
    "details": null
  },
  "meta": {
    "api_version": "2024.01",
    "request_id": "550e8400-e29b-41d4-a716-446655440000",
    "timestamp": "2026-01-21T10:23:44+01:00"
  }
}
```

**Маппинг HTTP статусов в коды ошибок:**

| HTTP Status | Error Code |
|-------------|------------|
| 400 | `bad_request` |
| 401 | `unauthorized` |
| 403 | `forbidden` |
| 404 | `not_found` |
| 422 | `unprocessable_entity` |
| 429 | `rate_limited` |
| 500 | `internal_error` |
| 502 | `bad_gateway` |
| 503 | `service_unavailable` |
| 504 | `gateway_timeout` |

**Преимущества единого формата:**

- Клиенты всегда знают структуру ответа
- Легче обрабатывать ошибки на фронтенде
- Request ID в каждом ответе упрощает support
- Timestamp помогает отлаживать проблемы с кэшированием

### 8. Health Endpoint (`lib/gateway/health_endpoint.rb`)

Предоставляет endpoints для мониторинга состояния Gateway.

**Endpoints:**

#### `/health/live` — Liveness Probe

Проверяет, что Gateway-процесс жив.

```json
{
  "status": "ok"
}
```

Используется Kubernetes/Docker для определения, нужно ли перезапустить контейнер.

#### `/health/ready` — Readiness Probe

Проверяет, готов ли Gateway принимать трафик.

```json
{
  "status": "ready",
  "healthy_backends": 5
}
```

Возвращает 503, если нет здоровых backends. Kubernetes не направит трафик на такой pod.

#### `/health` — General Health

Общая информация о состоянии:

```json
{
  "status": "degraded",
  "healthy_backends": 4,
  "total_backends": 5
}
```

Статусы:
- `ok` — все backends здоровы
- `degraded` — часть backends недоступна
- `unhealthy` — нет здоровых backends

#### `/health/detailed` — Detailed Status

Подробная информация о каждом backend:

```json
{
  "gateway": "ok",
  "uptime": "142s",
  "backends": {
    "http://localhost:3001": "unhealthy",
    "http://localhost:3011": "healthy",
    "http://localhost:3002": "healthy"
  },
  "timestamp": "2026-01-21T10:25:42+01:00"
}
```

Используется для debugging и мониторинга (Prometheus, Grafana).

## Паттерны устойчивости

### Circuit Breaker Pattern

**Проблема:** При падении backend-сервиса все запросы к нему будут висеть до timeout'а (например, 10 секунд). Если запросов много, threads Gateway исчерпаются, и он перестанет обрабатывать запросы даже к здоровым сервисам.

**Решение:** Circuit Breaker отслеживает количество ошибок и после порога начинает сразу отклонять запросы, не дожидаясь timeout'а.

**Пример:**

```
Time: 0s   Backend падает
Time: 1s   Request 1: 502 (timeout 10s) — ждем
Time: 2s   Request 2: 502 (timeout 10s) — ждем
Time: 3s   Request 3: 502 (timeout 10s) — ждем
Time: 11s  Request 1 завершается с ошибкой (failures: 1)
Time: 12s  Request 2 завершается с ошибкой (failures: 2)
Time: 13s  Request 3 завершается с ошибкой (failures: 3)
Time: 13s  Circuit открывается (OPEN state)
Time: 14s  Request 4: 503 немедленно (не ждем 10s!)
Time: 15s  Request 5: 503 немедленно
...
Time: 23s  Circuit переходит в HALF-OPEN
Time: 23s  Request N: пытаемся один запрос
           Если успех → CLOSED, если ошибка → снова OPEN
```

**Конфигурация в коде:**

```ruby
error_threshold: 3,    # 3 ошибки подряд
error_timeout: 10,     # 10 секунд в OPEN state
success_threshold: 2   # 2 успеха для закрытия
```

### Health Checking Pattern

**Проблема:** Load Balancer может продолжать отправлять запросы на упавший backend, даже если Circuit Breaker открыт.

**Решение:** Фоновый Health Checker периодически проверяет `/health` endpoint каждого backend'а и помечает недоступные как `unhealthy`.

**Синергия с Circuit Breaker:**

1. **Circuit Breaker** — реактивный (реагирует на ошибки во время запросов)
2. **Health Checker** — проактивный (заранее проверяет доступность)

Вместе они обеспечивают быстрое обнаружение и изоляцию сбоев.

### Graceful Degradation

**Идея:** Система продолжает частично работать, даже если часть сервисов недоступна.

**Реализовано:**

1. Load Balancer исключает unhealthy backends из ротации
2. Если есть хотя бы один healthy backend — запросы обрабатываются
3. `/health/ready` возвращает 503 только если ВСЕ backends мертвы

**Пример:**

Из двух реплик Users Service одна упала:
- Старое поведение: 50% запросов падают с ошибками
- Новое поведение: 100% запросов идут на здоровую реплику

### Timeout Management

**Правило:** `downstream_timeout < upstream_timeout`

```
Client → Gateway (30s) → Service A (10s) → Service B (5s)
```

Это оставляет запас времени на:
- Retry попытки
- Обработку и логирование ошибок
- Graceful timeout вместо резкого обрыва

**В коде:**

```ruby
f.options.timeout = 10           # Read timeout
f.options.open_timeout = 5       # Connection timeout
```

## Middleware Stack

Порядок middleware в `config.ru` критически важен:

```ruby
use Gateway::HealthEndpoint         # 1️⃣ Самым первым
use Gateway::Middleware::RequestTransformer    # 2️⃣
use Gateway::Middleware::ResponseTransformer   # 3️⃣
use Gateway::Router                 # 4️⃣
use Gateway::Middleware::CircuitBreaker        # 5️⃣
run Gateway::Proxy.new              # 6️⃣ В самом конце
```

**Почему такой порядок?**

### 1️⃣ Health Endpoint — Первым

Должен отвечать **до** любой другой логики, чтобы Kubernetes мог проверить liveness даже если Gateway перегружен.

### 2️⃣ Request Transformer

Добавляет Request-ID в самом начале, чтобы он был доступен всем последующим middleware.

### 3️⃣ Response Transformer

**Важно:** Middleware выполняются как стек (LIFO).

```ruby
use A  # Вызывается 1-м, завершается 3-м
use B  # Вызывается 2-м, завершается 2-м
run C  # Вызывается 3-м, завершается 1-м
```

Response Transformer должен быть **после** Router, чтобы обработать ответы от backend'ов.

### 4️⃣ Router

Определяет, куда направить запрос. Должен быть **до** Circuit Breaker и Proxy.

### 5️⃣ Circuit Breaker

Отслеживает ошибки от Proxy и управляет состоянием circuit'ов.

### 6️⃣ Proxy

Последний — делает фактический HTTP-запрос.

**Поток данных:**

```
→ Request →
1. Health Endpoint (пропускает /api/*)
2. Request Transformer (добавляет headers)
3. Response Transformer (пока ничего не делает)
4. Router (выбирает backend)
5. Circuit Breaker (проверяет state)
6. Proxy (делает HTTP-запрос)

← Response ←
6. Proxy (возвращает Faraday response)
5. Circuit Breaker (обрабатывает ошибки)
4. Router (tracking connections)
3. Response Transformer (оборачивает в {success, data, meta})
2. Request Transformer (ничего не делает)
1. Health Endpoint (пропускает)
```

## Конфигурация

### Добавление нового маршрута

В `lib/gateway/router.rb`:

```ruby
ROUTES = {
  %r{^/api/payments} => {
    backends: ['http://localhost:3004'],
    strip_prefix: '/api'
  }
}
```

### Добавление реплики сервиса

```ruby
%r{^/api/users} => {
  backends: [
    'http://localhost:3001',
    'http://localhost:3011',
    'http://localhost:3021'  # Новая реплика
  ],
  strip_prefix: '/api'
}
```

Health Checker автоматически начнет мониторить новый backend.

### Изменение стратегии балансировки

В `config.ru`:

```ruby
load_balancer = Gateway::LoadBalancer.new(
  health_checker,
  strategy: :least_connections  # или :round_robin, :random
)
```

### Настройка Circuit Breaker

В `lib/gateway/middleware/circuit_breaker.rb`:

```ruby
CIRCUIT_CONFIG = {
  'localhost:3001' => {
    name: 'users_service',
    error_threshold: 5,    # Больше терпимости к ошибкам
    error_timeout: 30      # Дольше ждем перед retry
  }
}
```

### Настройка Health Checker

В `lib/gateway/health_checker.rb`:

```ruby
HEALTH_CHECK_INTERVAL = 5   # Проверяем чаще
HEALTH_CHECK_TIMEOUT = 1    # Быстрее признаем недоступным
UNHEALTHY_THRESHOLD = 2     # Меньше терпимость
```

### Изменение timeouts

В `lib/gateway/proxy.rb`:

```ruby
Faraday.new(url: backend) do |f|
  f.options.timeout = 30         # Увеличили read timeout
  f.options.open_timeout = 10    # Увеличили connect timeout
  f.adapter :net_http
end
```

## Примеры использования

### Запуск системы

```bash
# 1. Запустить mock backend'ы
PORT=3001 bundle exec rackup mock_backend_with_id.ru -p 3001 &
PORT=3011 bundle exec rackup mock_backend_with_id.ru -p 3011 &
PORT=3002 bundle exec rackup mock_backend_with_id.ru -p 3002 &

# 2. Запустить Gateway
bundle exec rackup config.ru -p 4000

# 3. Проверить health
curl http://localhost:4000/health/detailed
```

### Базовый запрос

```bash
curl http://localhost:4000/api/users/1
```

Ответ:

```json
{
  "success": true,
  "data": {
    "id": 1,
    "name": "User 1",
    "served_by": "backend:3001"
  },
  "meta": {
    "api_version": "2024.01",
    "request_id": "550e8400-e29b-41d4-a716-446655440000",
    "timestamp": "2026-01-21T10:23:44+01:00"
  }
}
```

### Проверка load balancing

```bash
for i in {1..10}; do
  curl -s http://localhost:4000/api/users/1 | jq -r '.data.served_by'
done
```

Вывод (round-robin):

```
backend:3001
backend:3011
backend:3001
backend:3011
...
```

### Тестирование Circuit Breaker

```bash
# 1. Остановить один backend
kill $(lsof -ti:3001)

# 2. Сделать несколько запросов
for i in {1..10}; do
  echo "Request $i:"
  curl -s http://localhost:4000/api/users/1 | jq -r '.success, .error.code'
  sleep 0.5
done
```

Результат:

```
Request 1: true (пошел на 3011)
Request 2: false, bad_gateway (попытка на 3001, timeout)
Request 3: true (пошел на 3011)
Request 4: false, bad_gateway
...
Request 8: false, service_unavailable (circuit открылся!)
Request 9: true (все на 3011)
Request 10: true (все на 3011)
```

### Проверка health check

```bash
# Сразу после остановки backend
curl http://localhost:4000/health/detailed | jq .

# Через 30 секунд (3 health check цикла)
curl http://localhost:4000/health/detailed | jq .
```

Backend 3001 будет помечен как `unhealthy`.

### Distributed Tracing

Все запросы имеют Request-ID:

```bash
# Делаем запрос
curl -v http://localhost:4000/api/users/1 2>&1 | grep -i x-request-id

# Вывод:
< x-request-id: 550e8400-e29b-41d4-a716-446655440000
```

Этот ID можно искать в логах всех сервисов:

```bash
# Gateway logs
grep "550e8400-e29b-41d4-a716-446655440000" gateway.log

# Backend logs
grep "550e8400-e29b-41d4-a716-446655440000" users-service.log
```

## Monitoring и Debugging

### Важные метрики

Что нужно мониторить в продакшене:

1. **Gateway metrics:**
   - Request rate (requests/sec)
   - Error rate (4xx, 5xx)
   - Latency (p50, p95, p99)
   - Circuit breaker states

2. **Backend metrics:**
   - Health check success rate
   - Connection pool utilization
   - Timeout rate

3. **System metrics:**
   - CPU, Memory
   - Thread pool size
   - Open file descriptors

### Логирование

Добавить structured logging:

```ruby
# В Proxy
logger.info(
  event: 'proxy_request',
  request_id: env['gateway.request_id'],
  backend: backend,
  method: env['REQUEST_METHOD'],
  path: env['PATH_INFO'],
  duration_ms: duration
)
```

### Интеграция с Prometheus

Можно добавить endpoint `/metrics`:

```ruby
# lib/gateway/metrics_endpoint.rb
def call(env)
  if env['PATH_INFO'] == '/metrics'
    [200, {'Content-Type' => 'text/plain'}, [
      "gateway_requests_total{backend=\"users\"} 1234\n",
      "gateway_request_duration_seconds{backend=\"users\"} 0.123\n"
    ]]
  else
    @app.call(env)
  end
end
```

## Troubleshooting

### Gateway не стартует

**Проблема:** `Address already in use (Errno::EADDRINUSE)`

**Решение:**

```bash
# Найти процесс на порту 4000
lsof -ti:4000

# Убить процесс
kill $(lsof -ti:4000)
```

### Все запросы возвращают 503

**Причина:** Нет здоровых backends.

**Проверить:**

```bash
curl http://localhost:4000/health/detailed
```

**Решение:** Запустить backend'ы.

### Circuit не открывается

**Причина:** Порог ошибок не достигнут.

**Проверить конфигурацию:**

```ruby
error_threshold: 3  # Нужно 3 ошибки
```

**Решение:** Сделать больше запросов или уменьшить threshold.

### Load Balancer не распределяет нагрузку

**Причина:** Один из backends помечен unhealthy.

**Проверить:**

```bash
curl http://localhost:4000/health/detailed | jq '.backends'
```

**Решение:** Запустить упавший backend, подождать 2-3 health check цикла (~20-30 сек).

### Медленные запросы

**Причина:** Timeout'ы слишком большие.

**Решение:** Уменьшить timeouts в Proxy:

```ruby
f.options.timeout = 5          # Было 10
f.options.open_timeout = 2     # Было 5
```

## Дальнейшее развитие

### Rate Limiting

Добавить middleware для ограничения частоты запросов:

```ruby
# lib/gateway/middleware/rate_limiter.rb
class RateLimiter
  def initialize(app, redis:, limit: 100, period: 60)
    @app = app
    @redis = redis
    @limit = limit
    @period = period
  end

  def call(env)
    client_ip = env['REMOTE_ADDR']
    key = "rate_limit:#{client_ip}"

    count = @redis.incr(key)
    @redis.expire(key, @period) if count == 1

    if count > @limit
      return [429, {'Content-Type' => 'application/json'},
        [{ error: 'rate_limited', message: 'Too many requests' }.to_json]]
    end

    @app.call(env)
  end
end
```

### Authentication

```ruby
# lib/gateway/middleware/authentication.rb
class Authentication
  def call(env)
    token = env['HTTP_AUTHORIZATION']&.sub('Bearer ', '')

    unless valid_token?(token)
      return [401, {'Content-Type' => 'application/json'},
        [{ error: 'unauthorized' }.to_json]]
    end

    env['gateway.user_id'] = decode_token(token)['user_id']
    @app.call(env)
  end
end
```

### Caching

Кэширование GET-запросов:

```ruby
# lib/gateway/middleware/cache.rb
class Cache
  def initialize(app, redis:, ttl: 60)
    @app = app
    @redis = redis
    @ttl = ttl
  end

  def call(env)
    return @app.call(env) unless env['REQUEST_METHOD'] == 'GET'

    cache_key = "cache:#{env['PATH_INFO']}:#{env['QUERY_STRING']}"

    if cached = @redis.get(cache_key)
      return parse_cached_response(cached)
    end

    status, headers, body = @app.call(env)

    if status == 200
      @redis.setex(cache_key, @ttl, serialize_response(status, headers, body))
    end

    [status, headers, body]
  end
end
```

### Request Aggregation

BFF паттерн для мобильных клиентов:

```ruby
# lib/gateway/aggregators/profile_aggregator.rb
class ProfileAggregator
  def aggregate(user_id)
    futures = {
      user: Concurrent::Future.execute { fetch_user(user_id) },
      orders: Concurrent::Future.execute { fetch_orders(user_id) },
      recommendations: Concurrent::Future.execute { fetch_recommendations(user_id) }
    }

    {
      user: futures[:user].value,
      recent_orders: futures[:orders].value,
      recommendations: futures[:recommendations].value
    }
  end
end
```

### Канарочные деплои

Направлять 10% трафика на новую версию:

```ruby
# lib/gateway/canary_router.rb
class CanaryRouter
  def select_backend(user_id, backends)
    if canary_user?(user_id)
      backends.find { |b| b.include?('canary') } || backends.first
    else
      backends.reject { |b| b.include?('canary') }.sample
    end
  end

  def canary_user?(user_id)
    Digest::MD5.hexdigest(user_id.to_s).to_i(16) % 100 < 10
  end
end
```

## Заключение

Этот API Gateway демонстрирует ключевые паттерны построения устойчивых распределенных систем:

✅ **Routing** — маршрутизация на основе path
✅ **Load Balancing** — распределение нагрузки с health-aware логикой
✅ **Circuit Breaker** — защита от каскадных сбоев
✅ **Health Checking** — проактивный мониторинг backend'ов
✅ **Request/Response Transformation** — стандартизация API
✅ **Distributed Tracing** — отслеживание запросов через систему
✅ **Graceful Degradation** — частичная работоспособность при сбоях

Код готов к изучению и адаптации под реальные проекты!

## Полезные ссылки

- [Semian от Shopify](https://github.com/Shopify/semian) — production-ready circuit breaker
- [Faraday](https://github.com/lostisland/faraday) — HTTP client
- [Martin Fowler: Circuit Breaker](https://martinfowler.com/bliki/CircuitBreaker.html)
- [Netflix: Fault Tolerance](https://netflixtechblog.com/fault-tolerance-in-a-high-volume-distributed-system-91ab4faae74a)