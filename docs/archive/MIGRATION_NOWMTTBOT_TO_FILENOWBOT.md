# Миграция nowmttbot → filenowbot: Руководство для миграции gsfortextbot → golosnowbot

## 📋 Контекст

Этот документ описывает процесс миграции бота `nowmttbot` в `filenowbot`, который был выполнен успешно. Этот процесс должен быть использован как шаблон для миграции `gsfortextbot` → `golosnowbot`.

**Важно:** Папка `golosnowbot` уже существует в проекте, но она пустая или находится в разработке. Перед началом миграции необходимо **удалить все упоминания и файлы, связанные с текущим golosnowbot**, и только потом начинать миграцию.

---

## 🎯 Этап 0: Подготовка (ВАЖНО для golosnowbot)

### Для golosnowbot: Удаление существующей папки и упоминаний

1. **Удалить папку golosnowbot** (если она существует и пустая/в разработке):
   ```bash
   rm -rf golosnowbot/
   ```

2. **Найти и удалить все упоминания golosnowbot в конфигах:**
   - `config/services.json` - удалить секцию golosnowbot
   - `config/nginx.conf` - удалить upstream и location блоки для golosnowbot
   - `config/set-webhooks.sh` - удалить секцию настройки webhook для golosnowbot
   - `config/start-all-services.sh` - удалить секцию запуска golosnowbot
   - `docker-compose.prod.yml` - удалить сервис golosnowbot
   - `docker-compose.dev.yml` - удалить сервис golosnowbot
   - `Package.swift` - удалить target для golosnowbot (если есть)
   - `nowcontrollerbot/Sources/App/Controllers/NowControllerBotController.swift` - удалить упоминание golosnowbot из botDisplayNames
   - `config/env.example` - удалить GOLOSNOWBOT_TOKEN (если есть)
   - Все файлы документации в `docs/` - удалить упоминания golosnowbot

3. **Проверить базу данных:**
   - Если в базе есть записи для golosnowbot, их нужно будет удалить или обновить после миграции

---

## 📝 Этап 1: Подготовка (для nowmttbot это было выполнено)

1. ✅ Создан новый бот в BotFather с именем `@filenowbot`
2. ✅ Получен токен нового бота
3. ✅ Создан backup базы данных (если нужен)

---

## 🔄 Этап 2: Переименование папки и файлов

### 2.1 Переименование основной папки

```bash
mv nowmttbot filenowbot
```

### 2.2 Переименование файлов внутри папки

**Структура файлов, которые нужно переименовать:**

```
filenowbot/Sources/App/
├── entrypoint.swift          (NowmttEntrypoint → FileNowEntrypoint)
├── configure.swift           (обновить комментарии и логи)
├── routes.swift              (обновить пути и контроллер)
├── Controllers/
│   └── NowmttBotController.swift → FileNowBotController.swift
├── Models/
│   └── NowmttBotUpdate.swift → FileNowBotUpdate.swift
├── Services/
│   └── MonetizationService.swift (обновить комментарии)
└── Internal/
    ├── TikTokResolver.swift
    ├── YouTubeShortsResolver.swift
    ├── RateLimiter.swift
    └── UpdateDeduplicator.swift
```

**Что переименовать:**
- `NowmttBotController.swift` → `FileNowBotController.swift`
- `NowmttBotUpdate.swift` → `FileNowBotUpdate.swift`
- Все классы: `NowmttBotController` → `FileNowBotController`, `NowmttBotUpdate` → `FileNowBotUpdate`, и т.д.

---

## 💻 Этап 3: Обновление кода

### 3.1 Package.swift

**Изменения:**
```swift
// Было:
let package = Package(
    name: "NowmttBot",
    // ...
    targets: [
        .executableTarget(
            name: "NowmttBot",
            path: "nowmttbot/Sources/App"
        )
    ]
)

// Стало:
let package = Package(
    name: "FileNowBot",
    // ...
    targets: [
        .executableTarget(
            name: "FileNowBot",
            path: "filenowbot/Sources/App"
        )
    ]
)
```

### 3.2 entrypoint.swift

**Изменения:**
- Enum `NowmttEntrypoint` → `FileNowEntrypoint`
- Все упоминания `NowmttBot` → `FileNowBot`

### 3.3 configure.swift

**Изменения:**
- Комментарии: `(для NOWMTTBOT_TOKEN)` → `(для FILENOWBOT_TOKEN)`
- Logger: `"NowmttBot"` → `"FileNowBot"`
- `getPortFromConfig`: `"nowmttbot"` → `"filenowbot"`

### 3.4 routes.swift

**Изменения:**
- `NowmttBotController()` → `FileNowBotController()`
- Путь webhook: `app.post("nowmtt", "webhook"` → `app.post("filenow", "webhook"`

### 3.5 Controllers/FileNowBotController.swift

**Изменения:**
- Класс: `NowmttBotController` → `FileNowBotController`
- Все логи: `"NowmttBot"` → `"FileNowBot"`
- `NOWMTTBOT_TOKEN` → `FILENOWBOT_TOKEN`
- `NowmttBotUpdate` → `FileNowBotUpdate`
- `MonetizationService.checkAccess`: `botName: "nowmttbot"` → `botName: "filenowbot"`

### 3.6 Models/FileNowBotUpdate.swift

**Изменения:**
- Структуры: `NowmttBotUpdate` → `FileNowBotUpdate`, `NowmttMessage` → `FileNowMessage`, `NowmttChat` → `FileNowChat`

### 3.7 Services/MonetizationService.swift

**Изменения:**
- Комментарии: `/// Сервис монетизации для nowmttbot` → `/// Сервис монетизации для filenowbot`
- Все логи: `(nowmttbot)` → `(filenowbot)`

---

## ⚙️ Этап 4: Обновление конфигурационных файлов

### 4.1 config/services.json

**Изменения:**
```json
// Было:
{
  "nowmttbot": {
    "port": 8085,
    "webhook_url": "${BASE_URL}/nowmtt/webhook"
  }
}

// Стало:
{
  "filenowbot": {
    "port": 8085,
    "webhook_url": "${BASE_URL}/filenow/webhook"
  }
}
```

### 4.2 config/nginx.conf

**Изменения:**

1. **Upstream блок:**
```nginx
# Было:
upstream nowmttbot {
    server nowmttbot:8085;
}

# Стало (для локальной разработки):
upstream filenowbot {
    server 127.0.0.1:8085;
}

# Для продакшена (Docker):
upstream filenowbot {
    server filenowbot:8085;
}
```

2. **Location блок:**
```nginx
# Было:
location = /nowmtt/webhook {
    proxy_pass http://nowmttbot/webhook;
    # ...
}

location = /nowmtt/health {
    proxy_pass http://nowmttbot/health;
    # ...
}

# Стало:
location = /filenow/webhook {
    proxy_pass http://filenowbot/webhook;
    # ...
}

location = /filenow/health {
    proxy_pass http://filenowbot/health;
    # ...
}
```

**Важно:** Для локальной разработки на Mac нужно обновить основной конфиг Nginx (`/opt/homebrew/etc/nginx/nginx.conf`), а не только `config/nginx.conf`.

### 4.3 config/set-webhooks.sh

**Изменения:**
```bash
# Было:
if [ -z "$NOWMTTBOT_TOKEN" ]; then
    echo "⚠️ NOWMTTBOT_TOKEN не установлен, пропускаем..."
    continue
fi

WEBHOOK_URL="${BASE_URL}/nowmtt/webhook"
curl -X POST "https://api.telegram.org/bot${NOWMTTBOT_TOKEN}/setWebhook?url=${WEBHOOK_URL}"

# Стало:
if [ -z "$FILENOWBOT_TOKEN" ]; then
    echo "⚠️ FILENOWBOT_TOKEN не установлен, пропускаем..."
    continue
fi

WEBHOOK_URL="${BASE_URL}/filenow/webhook"
curl -X POST "https://api.telegram.org/bot${FILENOWBOT_TOKEN}/setWebhook?url=${WEBHOOK_URL}"
```

### 4.4 config/start-all-services.sh

**Изменения:**
```bash
# Было:
if [ -z "$NOWMTTBOT_TOKEN" ]; then
    echo "⚠️ NOWMTTBOT_TOKEN не установлен, пропускаем..."
    continue
fi

swift run NowmttBot

# Стало:
if [ -z "$FILENOWBOT_TOKEN" ]; then
    echo "⚠️ FILENOWBOT_TOKEN не установлен, пропускаем..."
    continue
fi

swift run FileNowBot
```

### 4.5 config/env.example

**Изменения:**
```bash
# Было:
NOWMTTBOT_TOKEN=123456:REPLACE_ME_NOWMTTBOT

# Стало:
FILENOWBOT_TOKEN=123456:REPLACE_ME_FILENOWBOT
```

Также обновить `NOWCONTROLLERBOT_BROADCAST_BOTS`:
```bash
# Было:
NOWCONTROLLERBOT_BROADCAST_BOTS=nowmttbot,neurfotobot,...

# Стало:
NOWCONTROLLERBOT_BROADCAST_BOTS=filenowbot,neurfotobot,...
```

### 4.6 docker-compose.prod.yml

**Изменения:**
```yaml
# Было:
  nowmttbot:
    build:
      context: .
      dockerfile: Dockerfile.prod
    environment:
      - PRODUCT=NowmttBot
    container_name: telegrambot_nowmttbot
    labels:
      - "traefik.http.routers.nowmttbot.rule=Host(`your-domain.com`) && PathPrefix(`/nowmtt/webhook`)"

# Стало:
  filenowbot:
    build:
      context: .
      dockerfile: Dockerfile.prod
    environment:
      - PRODUCT=FileNowBot
    container_name: telegrambot_filenowbot
    labels:
      - "traefik.http.routers.filenowbot.rule=Host(`your-domain.com`) && PathPrefix(`/filenow/webhook`)"
```

### 4.7 docker-compose.dev.yml

**Аналогичные изменения**, как в `docker-compose.prod.yml`, плюс:
```yaml
# Было:
command: swift run NowmttBot

# Стало:
command: swift run FileNowBot
```

---

## 🤖 Этап 5: Обновление NowControllerBot

### 5.1 Controllers/NowControllerBotController.swift

**Изменения:**
```swift
// Было:
let botDisplayNames: [String: String] = [
    "nowmttbot": "Тикток",
    // ...
]

// Стало:
let botDisplayNames: [String: String] = [
    "filenowbot": "Тикток",
    // ...
]
```

### 5.2 config/env.example (NOWCONTROLLERBOT_BROADCAST_BOTS)

Уже упомянуто в разделе 4.5.

---

## 📚 Этап 6: Обновление документации

### Файлы, которые нужно обновить:

1. **README.md**
   - Все упоминания `NowmttBot` → `FileNowBot`
   - Обновить описание бота (если изменилось)
   - Обновить пути webhook

2. **docs/QUICK_START.md**
   - `NOWMTTBOT_TOKEN` → `FILENOWBOT_TOKEN`
   - `swift run NowmttBot` → `swift run FileNowBot`
   - Обновить пути webhook

3. **docs/SETUP_GUIDE.md**
   - `NOWCONTROLLERBOT_BROADCAST_BOTS` с `nowmttbot` → `filenowbot`
   - Nginx location: `/nowmtt/webhook` → `/filenow/webhook`

4. **docs/ARCHITECTURE.md**
   - Все упоминания `nowmttbot` → `filenowbot`
   - Обновить классы и пути

5. **docs/DEPLOY.md**
   - Webhook URL: `/nowmtt/webhook` → `/filenow/webhook`

6. **docs/WEBHOOKS_EXPLAINED.md**
   - Обновить секцию для `FileNowBot`

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

---

## 🗄️ Этап 7: Обновление базы данных (на VPS)

**Важно:** Это нужно делать на VPS, не локально!

### SQL команды для выполнения на VPS:

```sql
-- Обновить имя бота в таблице bots (если есть)
UPDATE bots SET name = 'filenowbot' WHERE name = 'nowmttbot';

-- Обновить имя бота в таблице bot_settings (если есть)
UPDATE bot_settings SET bot_name = 'filenowbot' WHERE bot_name = 'nowmttbot';

-- Обновить имя бота в таблице subscriptions (если есть)
UPDATE subscriptions SET bot_name = 'filenowbot' WHERE bot_name = 'nowmttbot';

-- Проверить результат
SELECT * FROM bots WHERE name LIKE '%mtt%' OR name LIKE '%file%';
SELECT * FROM bot_settings WHERE bot_name LIKE '%mtt%' OR bot_name LIKE '%file%';
```

**Для golosnowbot:** Если в базе есть записи для старого golosnowbot, их нужно удалить или обновить.

---

## 🚀 Этап 8: Развертывание на VPS

### 8.1 Обновление config/.env на VPS

```bash
# Заменить токен
# Было:
NOWMTTBOT_TOKEN=old_token

# Стало:
FILENOWBOT_TOKEN=new_token

# Обновить NOWCONTROLLERBOT_BROADCAST_BOTS
# Было:
NOWCONTROLLERBOT_BROADCAST_BOTS=nowmttbot,neurfotobot,...

# Стало:
NOWCONTROLLERBOT_BROADCAST_BOTS=filenowbot,neurfotobot,...
```

### 8.2 Обновление Nginx на VPS

Обновить `config/nginx.conf` на VPS (аналогично разделу 4.2).

### 8.3 Пересборка и перезапуск Docker контейнера

```bash
# Остановить старый контейнер
docker-compose -f docker-compose.prod.yml stop nowmttbot
docker-compose -f docker-compose.prod.yml rm -f nowmttbot

# Пересобрать и запустить новый
docker-compose -f docker-compose.prod.yml up -d --build filenowbot

# Проверить логи
docker-compose -f docker-compose.prod.yml logs -f filenowbot
```

### 8.4 Настройка webhook на VPS

```bash
cd /path/to/project
./config/set-webhooks.sh
```

---

## ✅ Этап 9: Проверка и тестирование

### 9.1 Локальная проверка

1. Проверить, что бот запускается:
   ```bash
   swift run FileNowBot
   ```

2. Проверить health endpoint:
   ```bash
   curl http://127.0.0.1:8085/health
   ```

3. Проверить webhook через Nginx:
   ```bash
   curl -i http://127.0.0.1:8888/filenow/webhook -X POST -H "Content-Type: application/json" -d '{"update_id":999,"message":{"message_id":1,"chat":{"id":123},"text":"/start"}}'
   ```

4. Проверить webhook через Telegram API:
   ```bash
   curl "https://api.telegram.org/bot$(grep FILENOWBOT_TOKEN config/.env | cut -d= -f2)/getWebhookInfo" | python3 -m json.tool
   ```

### 9.2 Проверка на VPS

1. Проверить статус контейнера:
   ```bash
   docker-compose -f docker-compose.prod.yml ps filenowbot
   ```

2. Проверить логи:
   ```bash
   docker-compose -f docker-compose.prod.yml logs filenowbot
   ```

3. Проверить webhook:
   ```bash
   curl "https://api.telegram.org/bot<TOKEN>/getWebhookInfo"
   ```

---

## 🔍 Особые моменты, которые нужно учесть для golosnowbot

### 1. Структура проекта gsfortextbot

Перед миграцией нужно проанализировать структуру `gsfortextbot` и понять:
- Какие файлы и классы нужно переименовать
- Какие зависимости есть у бота
- Какие сервисы использует бот
- Какие модели и контроллеры есть

### 2. Порты и конфигурация

- Проверить, какой порт использует `gsfortextbot` (вероятно, 8083)
- Проверить, какой порт должен использовать `golosnowbot` (возможно, тот же или другой)
- Обновить `config/services.json` соответственно

### 3. Webhook пути

- Текущий путь для `gsfortextbot`: `/gs/text/webhook`
- Новый путь для `golosnowbot`: `/golosnow/webhook` (или другой, в зависимости от требований)

### 4. База данных

- Проверить, есть ли таблицы, связанные с `gsfortextbot`
- Обновить все записи в базе данных
- Удалить записи старого `golosnowbot` (если есть)

### 5. Дополнительные сервисы

Если `gsfortextbot` использует внешние сервисы (например, API для распознавания речи), нужно убедиться, что они правильно настроены для `golosnowbot`.

---

## 📋 Чеклист для миграции gsfortextbot → golosnowbot

### Подготовка
- [ ] Удалить папку `golosnowbot` (если существует)
- [ ] Удалить все упоминания `golosnowbot` из конфигов
- [ ] Создать новый бот в BotFather
- [ ] Получить токен нового бота
- [ ] Сделать backup базы данных

### Код
- [ ] Переименовать папку `gsfortextbot` → `golosnowbot`
- [ ] Переименовать все файлы и классы
- [ ] Обновить `Package.swift`
- [ ] Обновить все контроллеры, модели, сервисы
- [ ] Обновить все логи и комментарии

### Конфигурация
- [ ] Обновить `config/services.json`
- [ ] Обновить `config/nginx.conf` (и основной конфиг на Mac)
- [ ] Обновить `config/set-webhooks.sh`
- [ ] Обновить `config/start-all-services.sh`
- [ ] Обновить `config/env.example`
- [ ] Обновить `docker-compose.prod.yml`
- [ ] Обновить `docker-compose.dev.yml`

### Интеграции
- [ ] Обновить `NowControllerBot`
- [ ] Обновить `NOWCONTROLLERBOT_BROADCAST_BOTS`

### Документация
- [ ] Обновить `README.md`
- [ ] Обновить все файлы в `docs/`
- [ ] Обновить `docs/nginx.conf.example`

### База данных (на VPS)
- [ ] Выполнить SQL миграции
- [ ] Удалить записи старого `golosnowbot`

### Развертывание
- [ ] Обновить `config/.env` на VPS
- [ ] Обновить Nginx на VPS
- [ ] Пересобрать Docker контейнер
- [ ] Настроить webhook

### Тестирование
- [ ] Проверить локально
- [ ] Проверить на VPS
- [ ] Протестировать функциональность бота

---

## 🎯 Итоговые команды для быстрого старта

После анализа проекта и составления плана, можно использовать эти команды как отправную точку:

```bash
# 1. Удалить старый golosnowbot
rm -rf golosnowbot/

# 2. Переименовать папку
mv gsfortextbot golosnowbot

# 3. Найти все упоминания для замены
grep -r "gsfortextbot" . --exclude-dir=.git
grep -r "GSForTextBot" . --exclude-dir=.git
grep -r "gs/text" . --exclude-dir=.git

# 4. Найти все упоминания старого golosnowbot для удаления
grep -r "golosnowbot" . --exclude-dir=.git
grep -r "GolosNowBot" . --exclude-dir=.git
```

---

## 📝 Примечания

- Этот документ описывает процесс миграции `nowmttbot` → `filenowbot`, который был успешно выполнен
- Для миграции `gsfortextbot` → `golosnowbot` нужно адаптировать все шаги под структуру `gsfortextbot`
- Важно сначала удалить все упоминания старого `golosnowbot`, так как папка уже существует
- Все изменения должны быть протестированы локально перед развертыванием на VPS
- База данных обновляется только на VPS, не локально

---

**Дата создания:** 2025-01-24  
**Для миграции:** gsfortextbot → golosnowbot
