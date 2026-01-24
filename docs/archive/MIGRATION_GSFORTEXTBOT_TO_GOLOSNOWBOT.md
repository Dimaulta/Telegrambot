# Миграция gsfortextbot → golosnowbot: Подробный план миграции

## 📋 Контекст

Этот документ описывает процесс миграции бота `gsfortextbot` (преобразование голосовых в текст) в `golosnowbot`. Документ основан на успешной миграции `nowmttbot` → `filenowbot`.

**Важно:** Папка `golosnowbot` уже существует в проекте, но содержит другой функционал (Veo 3, TTS). Необходимо **полностью заменить содержимое golosnowbot** на миграцию из gsfortextbot.

---

## 🔍 Анализ текущего состояния

### Структура gsfortextbot

```
gsfortextbot/
├── docs/
│   └── SETUP_GSFORTEXTBOT.md
├── Sources/
│   └── App/
│       ├── Application+SaluteSpeech.swift
│       ├── configure.swift
│       ├── Controllers/
│       │   └── GSForTextBotController.swift
│       ├── entrypoint.swift
│       ├── Internal/
│       │   └── VoiceAudioSessionManager.swift
│       ├── Models/
│       │   └── GSForTextBotUpdate.swift
│       ├── routes.swift
│       └── Services/
│           ├── MonetizationService.swift
│           ├── SaluteSpeechAuthService.swift
│           └── SaluteSpeechRecognitionService.swift
```

### Текущие настройки gsfortextbot

- **Порт:** 8083
- **Webhook путь:** `/gs/text/webhook`
- **Токен:** `GSFORTEXTBOT_TOKEN`
- **Bot name в MonetizationService:** `"gsfortextbot"`
- **Product name:** `GSForTextBot`
- **Entrypoint enum:** `GSForTextEntrypoint`

### Текущие настройки golosnowbot (существующие)

- **Порт:** 8087 (в config/services.json)
- **Webhook путь:** `/golosnow/webhook` (уже настроен в set-webhooks.sh)
- **Токен:** `GOLOSNOWBOT_TOKEN` (уже есть в env)
- **Product name:** закомментирован в Package.swift
- **Содержимое:** другой функционал (Veo 3, TTS) - нужно заменить

---

## 🎯 Этап 0: Подготовка (ВАЖНО)

### 0.1 Резервное копирование

```bash
# Создать backup текущего golosnowbot (если нужен)
cp -r golosnowbot golosnowbot.backup

# Создать backup базы данных (на VPS)
# sqlite3 config/monetization.sqlite ".backup backup_before_migration.sqlite"
```

### 0.2 Очистка golosnowbot

**ВАЖНО:** Полностью удалить содержимое golosnowbot, так как там другой функционал:

```bash
# Удалить все файлы в golosnowbot (кроме папки)
rm -rf golosnowbot/Sources/*
rm -rf golosnowbot/docs/*
rm -rf golosnowbot/config/*
```

---

## 📝 Этап 1: Переименование папки и файлов

### 1.1 Копирование структуры из gsfortextbot

```bash
# Копируем всю структуру из gsfortextbot в golosnowbot
cp -r gsfortextbot/Sources/* golosnowbot/Sources/
cp -r gsfortextbot/docs/* golosnowbot/docs/ 2>/dev/null || mkdir -p golosnowbot/docs
```

### 1.2 Переименование файлов

**Файлы для переименования:**

```
golosnowbot/Sources/App/
├── entrypoint.swift          (GSForTextEntrypoint → GolosNowEntrypoint)
├── configure.swift           (обновить комментарии и логи)
├── routes.swift              (обновить пути и контроллер)
├── Controllers/
│   └── GSForTextBotController.swift → GolosNowBotController.swift
├── Models/
│   └── GSForTextBotUpdate.swift → GolosNowBotUpdate.swift
├── Services/
│   ├── MonetizationService.swift (обновить комментарии)
│   ├── SaluteSpeechAuthService.swift (без изменений)
│   └── SaluteSpeechRecognitionService.swift (без изменений)
└── Internal/
    └── VoiceAudioSessionManager.swift (без изменений)
```

**Команды для переименования:**

```bash
cd golosnowbot/Sources/App
mv Controllers/GSForTextBotController.swift Controllers/GolosNowBotController.swift
mv Models/GSForTextBotUpdate.swift Models/GolosNowBotUpdate.swift
```

---

## 💻 Этап 2: Обновление кода

### 2.1 Package.swift

**Изменения:**
```swift
// Было (закомментировано):
// .executableTarget(
//     name: "GolosNowBot",
//     dependencies: [...],
//     path: "golosnowbot/Sources/App"
// ),

// Стало (раскомментировать и обновить):
.executableTarget(
    name: "GolosNowBot",
    dependencies: [
        .product(name: "Vapor", package: "vapor"),
        .product(name: "Fluent", package: "fluent"),
        .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
    ],
    path: "golosnowbot/Sources/App"
),

// Удалить старый target для GSForTextBot:
// .executableTarget(
//     name: "GSForTextBot",
//     ...
// ),
```

### 2.2 entrypoint.swift

**Изменения:**
```swift
// Было:
@main
enum GSForTextEntrypoint {
    static func main() async throws {
        // ...
    }
}

// Стало:
@main
enum GolosNowEntrypoint {
    static func main() async throws {
        // ...
    }
}
```

### 2.3 configure.swift

**Изменения:**
```swift
// Было:
func getPortFromConfig(serviceName: String) -> Int {
    // ...
    return 8083 // fallback
}

public func configure(_ app: Application) async throws {
    let port = getPortFromConfig(serviceName: "gsfortextbot")
    // ...
}

// Стало:
func getPortFromConfig(serviceName: String) -> Int {
    // ...
    return 8087 // fallback (новый порт для golosnowbot)
}

public func configure(_ app: Application) async throws {
    let port = getPortFromConfig(serviceName: "golosnowbot")
    // ...
}
```

**Также обновить логи:**
- `"SaluteSpeech TLS: ..."` → оставить как есть (это общий сервис)
- `MonetizationService.ensureDatabase` → оставить как есть

### 2.4 routes.swift

**Изменения:**
```swift
// Было:
func routes(_ app: Application) throws {
    let controller = GSForTextBotController(app: app)
    app.post("webhook", use: controller.handleWebhook)
    app.post("gs", "text", "webhook", use: controller.handleWebhook)
}

// Стало:
func routes(_ app: Application) throws {
    let controller = GolosNowBotController(app: app)
    app.post("webhook", use: controller.handleWebhook)
    app.post("golosnow", "webhook", use: controller.handleWebhook)
}
```

### 2.5 Controllers/GolosNowBotController.swift

**Изменения:**

1. **Класс:**
```swift
// Было:
final class GSForTextBotController {
    private let botToken: String
    
    init(app: Application) {
        self.botToken = Environment.get("GSFORTEXTBOT_TOKEN") ?? ""
    }
}

// Стало:
final class GolosNowBotController {
    private let botToken: String
    
    init(app: Application) {
        self.botToken = Environment.get("GOLOSNOWBOT_TOKEN") ?? ""
    }
}
```

2. **Все логи:**
```swift
// Было:
req.logger.error("GSForTextBotController: ...")
req.logger.info("GSForTextBot: ...")

// Стало:
req.logger.error("GolosNowBotController: ...")
req.logger.info("GolosNowBot: ...")
```

3. **MonetizationService:**
```swift
// Было:
MonetizationService.checkAccess(
    botName: "gsfortextbot",
    ...
)

// Стало:
MonetizationService.checkAccess(
    botName: "golosnowbot",
    ...
)
```

4. **Модели:**
```swift
// Было:
let update: GSForTextBotUpdate
update = try req.content.decode(GSForTextBotUpdate.self)

// Стало:
let update: GolosNowBotUpdate
update = try req.content.decode(GolosNowBotUpdate.self)
```

5. **Все упоминания в тексте ошибок:**
```swift
// Было:
"GSForTextBotController: GSFORTEXTBOT_TOKEN is not configured"

// Стало:
"GolosNowBotController: GOLOSNOWBOT_TOKEN is not configured"
```

### 2.6 Models/GolosNowBotUpdate.swift

**Изменения:**
```swift
// Было:
struct GSForTextBotUpdate: Content {
    // ...
}

struct TelegramMessage: Content {
    // ...
}

struct TelegramChat: Content {
    // ...
}

// Стало:
struct GolosNowBotUpdate: Content {
    // ...
}

// TelegramMessage и TelegramChat можно оставить как есть,
// или переименовать в GolosNowMessage, GolosNowChat для консистентности
```

**Рекомендация:** Оставить `TelegramMessage` и `TelegramChat` как есть, так как это общие структуры Telegram API.

### 2.7 Services/MonetizationService.swift

**Изменения:**
```swift
// Было (в комментариях):
/// Сервис монетизации для gsfortextbot

// Стало:
/// Сервис монетизации для golosnowbot
```

**Важно:** `MonetizationService` - это общий сервис, используется всеми ботами. Не нужно менять логику, только комментарии если есть специфичные для gsfortextbot.

### 2.8 Application+SaluteSpeech.swift

**Проверить:** Если файл содержит специфичные для gsfortextbot упоминания, обновить их. Скорее всего, файл общий и не требует изменений.

### 2.9 Internal/VoiceAudioSessionManager.swift

**Проверить:** Если содержит специфичные логи или комментарии для gsfortextbot, обновить. Скорее всего, не требует изменений.

---

## ⚙️ Этап 3: Обновление конфигурационных файлов

### 3.1 config/services.json

**Изменения:**
```json
// Было:
{
  "services": {
    "gsfortextbot": {
      "url": "http://localhost:8083",
      "routes": ["/webhook"],
      "enabled": true,
      "webhook_url": "${BASE_URL}/webhook",
      "name": "GS For Text Bot"
    },
    "golosnowbot": {
      "url": "http://localhost:8087",
      "routes": ["/webhook", "/golosnow/webhook"],
      "enabled": true,
      "webhook_url": "${BASE_URL}/golosnow/webhook",
      "name": "GolosNowBot - Text to Speech (озвучивает пересланный текст голосом)"
    }
  }
}

// Стало (удалить gsfortextbot, обновить golosnowbot):
{
  "services": {
    "golosnowbot": {
      "url": "http://localhost:8087",
      "routes": ["/webhook", "/golosnow/webhook"],
      "enabled": true,
      "webhook_url": "${BASE_URL}/golosnow/webhook",
      "name": "GolosNowBot - Voice to Text (преобразует голосовые в текст)"
    }
  }
}
```

### 3.2 config/nginx.conf

**Изменения:**

1. **Upstream блок:**
```nginx
# Было:
upstream gsfortextbot {
    server gsfortextbot:8083;
}

# Стало (для локальной разработки):
upstream golosnowbot {
    server 127.0.0.1:8087;
}

# Для продакшена (Docker):
upstream golosnowbot {
    server golosnowbot:8087;
}
```

2. **Location блок:**
```nginx
# Было:
location = /gs/text/webhook {
    proxy_pass http://gsfortextbot/webhook;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# Стало:
location = /golosnow/webhook {
    proxy_pass http://golosnowbot/webhook;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

**Важно:** Для локальной разработки на Mac нужно обновить основной конфиг Nginx (`/opt/homebrew/etc/nginx/nginx.conf`), а не только `config/nginx.conf`.

### 3.3 config/set-webhooks.sh

**Изменения:**
```bash
# Было:
# ============================================
# GSFORTEXTBOT (Voice to Text)
# ============================================
if [ -z "$GSFORTEXTBOT_TOKEN" ]; then
    echo "⚠️ GSFORTEXTBOT_TOKEN не установлен, пропускаем..."
else
    echo "🔧 Настройка webhook для GS For Text Bot..."
    echo "📡 URL: ${BASE_URL}/gs/text/webhook"
    
    curl -sS -X POST "https://api.telegram.org/bot${GSFORTEXTBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/gs/text/webhook\"}"
    
    echo ""
    echo "✅ Webhook для GS For Text Bot настроен!"
    echo ""
fi

# Стало (обновить существующую секцию GOLOSNOWBOT):
# ============================================
# GOLOSNOWBOT (Voice to Text)
# ============================================
if [ -z "$GOLOSNOWBOT_TOKEN" ]; then
    echo "⚠️ GOLOSNOWBOT_TOKEN не установлен, пропускаем..."
else
    echo "🔧 Настройка webhook для GolosNowBot..."
    echo "📡 URL: ${BASE_URL}/golosnow/webhook"
    
    payload="{\"url\":\"${BASE_URL}/golosnow/webhook\""
    if [ -n "$GOLOSNOWBOT_WEBHOOK_SECRET" ]; then
        if [[ "$GOLOSNOWBOT_WEBHOOK_SECRET" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            payload="${payload},\"secret_token\":\"${GOLOSNOWBOT_WEBHOOK_SECRET}\""
        else
            echo "⚠️ GOLOSNOWBOT_WEBHOOK_SECRET содержит недопустимые символы, используем без secret token"
        fi
    fi
    payload="${payload}}"
    
    curl -sS -X POST "https://api.telegram.org/bot${GOLOSNOWBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "${payload}"
    
    echo ""
    echo "✅ Webhook для GolosNowBot настроен!"
    echo "📋 Проверка:"
    curl -sS "https://api.telegram.org/bot${GOLOSNOWBOT_TOKEN}/getWebhookInfo"
    echo ""
    echo ""
fi
```

**Примечание:** Секция для `GOLOSNOWBOT` уже существует в файле, нужно обновить описание с "Text to Speech" на "Voice to Text".

### 3.4 config/start-all-services.sh

**Изменения:**
```bash
# Было:
# 4. GSForTextBot
if [ -n "$GSFORTEXTBOT_TOKEN" ]; then
    open_terminal_tab "GSForTextBot" \
        "cd '$PROJECT_DIR' && set -a; source config/.env; set +a && swift run GSForTextBot"
else
    echo "⚠️  GSFORTEXTBOT_TOKEN не установлен, пропускаем GSForTextBot"
fi

# Стало (заменить на GolosNowBot или добавить после существующего):
# 4. GolosNowBot
if [ -n "$GOLOSNOWBOT_TOKEN" ]; then
    open_terminal_tab "GolosNowBot" \
        "cd '$PROJECT_DIR' && set -a; source config/.env; set +a && swift run GolosNowBot"
else
    echo "⚠️  GOLOSNOWBOT_TOKEN не установлен, пропускаем GolosNowBot"
fi
```

### 3.5 config/env.example

**Изменения:**
```bash
# Было:
# GSFORTEXTBOT - БОТ ПРЕВРАЩАЕТ ЛЮБЫЕ ПРИСЛАННЫЕ ГОЛОСОВЫЕ СООБЩЕНИЯ В ТЕКСТ
GSFORTEXTBOT_TOKEN=
SALUTESPEECH_CLIENT_ID=
SALUTESPEECH_SCOPE=SALUTE_SPEECH_PERS
SALUTESPEECH_AUTH_KEY="YOUR-AUTH-KEY"
SALUTESPEECH_TOKEN_URL=https://ngw.devices.sberbank.ru:9443/api/v2/oauth
SALUTESPEECH_API_BASE=https://smartspeech.sber.ru
SALUTESPEECH_TOKEN_LIFETIME=1800

# Стало (обновить существующую секцию GOLOSNOWBOT или добавить):
# GOLOSNOWBOT - БОТ ПРЕВРАЩАЕТ ЛЮБЫЕ ПРИСЛАННЫЕ ГОЛОСОВЫЕ СООБЩЕНИЯ В ТЕКСТ
GOLOSNOWBOT_TOKEN=
SALUTESPEECH_CLIENT_ID=
SALUTESPEECH_SCOPE=SALUTE_SPEECH_PERS
SALUTESPEECH_AUTH_KEY="YOUR-AUTH-KEY"
SALUTESPEECH_TOKEN_URL=https://ngw.devices.sberbank.ru:9443/api/v2/oauth
SALUTESPEECH_API_BASE=https://smartspeech.sber.ru
SALUTESPEECH_TOKEN_LIFETIME=1800
```

**Также обновить `NOWCONTROLLERBOT_BROADCAST_BOTS`:**
```bash
# Было:
NOWCONTROLLERBOT_BROADCAST_BOTS=filenowbot,gsfortextbot,neurfotobot,...

# Стало:
NOWCONTROLLERBOT_BROADCAST_BOTS=filenowbot,golosnowbot,neurfotobot,...
```

### 3.6 docker-compose.prod.yml

**Изменения:**
```yaml
# Было:
  gsfortextbot:
    build:
      context: .
      dockerfile: Dockerfile.prod
      args:
        PRODUCT: GSForTextBot
        PORT: 8083
    container_name: telegrambot_gsfortextbot
    labels:
      - "traefik.http.routers.gsfortextbot.rule=Host(`nowbots.ru`) && PathPrefix(`/gs/text/webhook`)"
      - "traefik.http.routers.gsfortextbot.middlewares=gsfortextbot-strip"
      - "traefik.http.middlewares.gsfortextbot-strip.stripprefix.prefixes=/gs/text"
      - "traefik.http.services.gsfortextbot.loadbalancer.server.port=8083"

# Стало (добавить или обновить секцию golosnowbot):
  golosnowbot:
    build:
      context: .
      dockerfile: Dockerfile.prod
      args:
        PRODUCT: GolosNowBot
        PORT: 8087
    container_name: telegrambot_golosnowbot
    restart: unless-stopped
    env_file:
      - config/.env
    environment:
      - LOG_LEVEL=${LOG_LEVEL:-info}
    volumes:
      - ./golosnowbot:/app/golosnowbot
      - ./config:/app/config
    networks:
      - telegrambot_network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.golosnowbot.rule=Host(`nowbots.ru`) && PathPrefix(`/golosnow/webhook`)"
      - "traefik.http.routers.golosnowbot.entrypoints=websecure"
      - "traefik.http.routers.golosnowbot.tls.certresolver=letsencrypt"
      - "traefik.http.routers.golosnowbot.middlewares=golosnowbot-strip"
      - "traefik.http.middlewares.golosnowbot-strip.stripprefix.prefixes=/golosnow"
      - "traefik.http.services.golosnowbot.loadbalancer.server.port=8087"
    depends_on:
      nowcontrollerbot:
        condition: service_healthy
```

### 3.7 docker-compose.dev.yml

**Изменения:**
```yaml
# Было:
  # GSForTextBot
  gsfortextbot:
    build:
      context: .
      dockerfile: Dockerfile.dev
      args:
        PRODUCT: GSForTextBot
    container_name: telegrambot_dev_gsfortextbot
    # ...

# Стало (добавить или обновить секцию golosnowbot):
  # GolosNowBot
  golosnowbot:
    build:
      context: .
      dockerfile: Dockerfile.dev
      args:
        PRODUCT: GolosNowBot
    container_name: telegrambot_dev_golosnowbot
    restart: unless-stopped
    env_file:
      - config/.env
    environment:
      - LOG_LEVEL=debug
    volumes:
      - .:/app
      - ./config:/app/config
    networks:
      - telegrambot_dev_network
    depends_on:
      - nowcontrollerbot
```

---

## 🤖 Этап 4: Обновление NowControllerBot

### 4.1 Controllers/NowControllerBotController.swift

**Изменения:**
```swift
// Было:
private static let botDisplayNames: [String: String] = [
    "filenowbot": "Тикток",
    "gsfortextbot": "Голос",
    "roundsvideobot": "Кружочек",
    "neurfotobot": "Нейрофото",
    "contentfabrikabot": "Посты",
    "pereskaznowbot": "Пересказ"
]

// Стало:
private static let botDisplayNames: [String: String] = [
    "filenowbot": "Тикток",
    "golosnowbot": "Голос",  // Изменено с gsfortextbot
    "roundsvideobot": "Кружочек",
    "neurfotobot": "Нейрофото",
    "contentfabrikabot": "Посты",
    "pereskaznowbot": "Пересказ"
]
```

**Также проверить все места, где используется `"gsfortextbot"` в коде:**
- Поиск по файлу: `grep -n "gsfortextbot" nowcontrollerbot/Sources/App/Controllers/NowControllerBotController.swift`
- Заменить все вхождения на `"golosnowbot"`

---

## 📚 Этап 5: Обновление документации

### Файлы для обновления:

1. **README.md**
   - Все упоминания `GSForTextBot` → `GolosNowBot`
   - Обновить описание бота
   - Обновить пути webhook: `/gs/text/webhook` → `/golosnow/webhook`

2. **docs/QUICK_START.md**
   - `GSFORTEXTBOT_TOKEN` → `GOLOSNOWBOT_TOKEN`
   - `swift run GSForTextBot` → `swift run GolosNowBot`
   - Обновить пути webhook

3. **docs/SETUP_GUIDE.md**
   - `NOWCONTROLLERBOT_BROADCAST_BOTS` с `gsfortextbot` → `golosnowbot`
   - Nginx location: `/gs/text/webhook` → `/golosnow/webhook`

4. **docs/ARCHITECTURE.md**
   - Все упоминания `gsfortextbot` → `golosnowbot`
   - Обновить классы: `GSForTextBotController` → `GolosNowBotController`
   - Обновить пути

5. **docs/DEPLOY.md**
   - Webhook URL: `/gs/text/webhook` → `/golosnow/webhook`

6. **docs/WEBHOOKS_EXPLAINED.md**
   - Обновить секцию для `GolosNowBot`

7. **docs/TRAEFIK_SETUP.md**
   - Обновить Traefik labels для нового пути

8. **docs/DOCKER_DEPENDENCIES.md**
   - Обновить упоминания бота

9. **docs/DATABASE_ARCHITECTURE.md**
   - Обновить упоминания бота в базе данных

10. **docs/VERIFY.md**
    - Обновить команды проверки для нового пути

11. **docs/nginx.conf.example**
    - Обновить location блоки и комментарии

12. **golosnowbot/docs/SETUP_GSFORTEXTBOT.md** (переименовать)
    - Переименовать файл в `SETUP_GOLOSNOWBOT.md`
    - Обновить все упоминания внутри файла

---

## 🗄️ Этап 6: Обновление базы данных (на VPS)

**Важно:** Это нужно делать на VPS, не локально!

### SQL команды для выполнения на VPS:

```sql
-- Обновить имя бота в таблице bots (если есть)
UPDATE bots SET name = 'golosnowbot' WHERE name = 'gsfortextbot';

-- Обновить имя бота в таблице bot_settings (если есть)
UPDATE bot_settings SET bot_name = 'golosnowbot' WHERE bot_name = 'gsfortextbot';

-- Обновить имя бота в таблице subscriptions (если есть)
UPDATE subscriptions SET bot_name = 'golosnowbot' WHERE bot_name = 'gsfortextbot';

-- Проверить результат
SELECT * FROM bots WHERE name LIKE '%gsfortext%' OR name LIKE '%golosnow%';
SELECT * FROM bot_settings WHERE bot_name LIKE '%gsfortext%' OR bot_name LIKE '%golosnow%';
SELECT * FROM subscriptions WHERE bot_name LIKE '%gsfortext%' OR bot_name LIKE '%golosnow%';
```

---

## 🚀 Этап 7: Развертывание на VPS

### 7.1 Обновление config/.env на VPS

```bash
# Убедиться, что токен обновлен (пользователь уже сделал это)
# GOLOSNOWBOT_TOKEN=новый_токен

# Обновить NOWCONTROLLERBOT_BROADCAST_BOTS
# Было:
# NOWCONTROLLERBOT_BROADCAST_BOTS=filenowbot,gsfortextbot,neurfotobot,...

# Стало:
# NOWCONTROLLERBOT_BROADCAST_BOTS=filenowbot,golosnowbot,neurfotobot,...
```

### 7.2 Обновление Nginx на VPS

Обновить `config/nginx.conf` на VPS (аналогично разделу 3.2).

### 7.3 Пересборка и перезапуск Docker контейнера

```bash
# Остановить старый контейнер (если был запущен gsfortextbot)
docker-compose -f docker-compose.prod.yml stop gsfortextbot
docker-compose -f docker-compose.prod.yml rm -f gsfortextbot

# Пересобрать и запустить новый
docker-compose -f docker-compose.prod.yml up -d --build golosnowbot

# Проверить логи
docker-compose -f docker-compose.prod.yml logs -f golosnowbot
```

### 7.4 Настройка webhook на VPS

```bash
cd /path/to/project
./config/set-webhooks.sh
```

---

## ✅ Этап 8: Проверка и тестирование

### 8.1 Локальная проверка

1. Проверить, что бот запускается:
   ```bash
   swift run GolosNowBot
   ```

2. Проверить health endpoint:
   ```bash
   curl http://127.0.0.1:8087/health
   ```

3. Проверить webhook через Nginx:
   ```bash
   curl -i http://127.0.0.1:8888/golosnow/webhook -X POST \
     -H "Content-Type: application/json" \
     -d '{"update_id":999,"message":{"message_id":1,"chat":{"id":123},"text":"/start"}}'
   ```

4. Проверить webhook через Telegram API:
   ```bash
   curl "https://api.telegram.org/bot$(grep GOLOSNOWBOT_TOKEN config/.env | cut -d= -f2)/getWebhookInfo" | python3 -m json.tool
   ```

### 8.2 Проверка на VPS

1. Проверить статус контейнера:
   ```bash
   docker-compose -f docker-compose.prod.yml ps golosnowbot
   ```

2. Проверить логи:
   ```bash
   docker-compose -f docker-compose.prod.yml logs golosnowbot
   ```

3. Проверить webhook:
   ```bash
   curl "https://api.telegram.org/bot<TOKEN>/getWebhookInfo"
   ```

---

## 📋 Чеклист для миграции

### Подготовка
- [ ] Создать backup текущего golosnowbot
- [ ] Создать backup базы данных (на VPS)
- [ ] Очистить содержимое golosnowbot
- [ ] Создать новый бот в BotFather (если еще не создан)
- [ ] Получить токен нового бота
- [ ] Обновить config/.env с новым токеном

### Код
- [ ] Скопировать структуру из gsfortextbot в golosnowbot
- [ ] Переименовать все файлы и классы
- [ ] Обновить `Package.swift`
- [ ] Обновить `entrypoint.swift`
- [ ] Обновить `configure.swift`
- [ ] Обновить `routes.swift`
- [ ] Обновить `GolosNowBotController.swift`
- [ ] Обновить `GolosNowBotUpdate.swift`
- [ ] Обновить все логи и комментарии
- [ ] Обновить `MonetizationService.checkAccess` с новым botName

### Конфигурация
- [ ] Обновить `config/services.json`
- [ ] Обновить `config/nginx.conf` (и основной конфиг на Mac)
- [ ] Обновить `config/set-webhooks.sh`
- [ ] Обновить `config/start-all-services.sh`
- [ ] Обновить `config/env.example`
- [ ] Обновить `docker-compose.prod.yml`
- [ ] Обновить `docker-compose.dev.yml`

### Интеграции
- [ ] Обновить `NowControllerBot` (botDisplayNames)
- [ ] Обновить `NOWCONTROLLERBOT_BROADCAST_BOTS` в env

### Документация
- [ ] Обновить `README.md`
- [ ] Обновить все файлы в `docs/`
- [ ] Обновить `docs/nginx.conf.example`
- [ ] Переименовать `golosnowbot/docs/SETUP_GSFORTEXTBOT.md` → `SETUP_GOLOSNOWBOT.md`

### База данных (на VPS)
- [ ] Выполнить SQL миграции
- [ ] Проверить обновление записей

### Развертывание
- [ ] Обновить `config/.env` на VPS
- [ ] Обновить Nginx на VPS
- [ ] Пересобрать Docker контейнер
- [ ] Настроить webhook

### Тестирование
- [ ] Проверить локально
- [ ] Проверить на VPS
- [ ] Протестировать функциональность бота (отправка голосового → получение текста)

---

## 🎯 Итоговые команды для быстрого старта

После анализа проекта и составления плана, можно использовать эти команды как отправную точку:

```bash
# 1. Backup текущего golosnowbot
cp -r golosnowbot golosnowbot.backup

# 2. Очистить golosnowbot
rm -rf golosnowbot/Sources/* golosnowbot/docs/* golosnowbot/config/*

# 3. Копировать структуру из gsfortextbot
cp -r gsfortextbot/Sources/* golosnowbot/Sources/
cp -r gsfortextbot/docs/* golosnowbot/docs/ 2>/dev/null || mkdir -p golosnowbot/docs

# 4. Переименовать файлы
cd golosnowbot/Sources/App
mv Controllers/GSForTextBotController.swift Controllers/GolosNowBotController.swift
mv Models/GSForTextBotUpdate.swift Models/GolosNowBotUpdate.swift

# 5. Найти все упоминания для замены
cd ../../..
grep -r "gsfortextbot" . --exclude-dir=.git --exclude-dir=golosnowbot.backup
grep -r "GSForTextBot" . --exclude-dir=.git --exclude-dir=golosnowbot.backup
grep -r "gs/text" . --exclude-dir=.git --exclude-dir=golosnowbot.backup
grep -r "GSFORTEXTBOT_TOKEN" . --exclude-dir=.git --exclude-dir=golosnowbot.backup
```

---

## 📝 Примечания

- Этот документ описывает процесс миграции `gsfortextbot` → `golosnowbot`
- Важно сначала очистить существующий `golosnowbot`, так как там другой функционал
- Все изменения должны быть протестированы локально перед развертыванием на VPS
- База данных обновляется только на VPS, не локально
- Порт меняется с 8083 на 8087
- Webhook путь меняется с `/gs/text/webhook` на `/golosnow/webhook`
- SaluteSpeech API настройки остаются теми же (токены, сертификаты)

---

**Дата создания:** 2025-01-24  
**Для миграции:** gsfortextbot → golosnowbot  
**Основан на:** MIGRATION_NOWMTTBOT_TO_FILENOWBOT.md
