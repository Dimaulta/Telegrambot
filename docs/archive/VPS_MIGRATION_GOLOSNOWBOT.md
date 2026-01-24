# Инструкция для миграции gsfortextbot → golosnowbot на VPS (Linux)

## 📋 Важно перед началом

**На VPS используется Traefik, не Nginx!** Все настройки проксирования делаются через Traefik labels в `docker-compose.prod.yml`.

---

## 🔍 Что проверить ПЕРЕД сборкой контейнеров

### 1. Проверка текущего состояния

```bash
# Проверить, какие контейнеры запущены
cd /root/Telegrambot
docker compose -f docker-compose.prod.yml ps

# Проверить, есть ли контейнер gsfortextbot
docker ps | grep gsfortextbot

# Проверить, есть ли контейнер golosnowbot
docker ps | grep golosnowbot
```

### 2. Проверка базы данных

```bash
# Проверить, существует ли база данных
ls -la /root/Telegrambot/config/monetization.sqlite

# Проверить текущие записи для gsfortextbot и golosnowbot
sqlite3 /root/Telegrambot/config/monetization.sqlite <<EOF
SELECT bot_name, COUNT(*) as count 
FROM sponsor_campaigns 
WHERE bot_name IN ('gsfortextbot', 'golosnowbot') 
GROUP BY bot_name;

SELECT bot_name, require_subscription, require_all_channels 
FROM bot_settings 
WHERE bot_name IN ('gsfortextbot', 'golosnowbot');
EOF
```

### 3. Проверка config/.env

```bash
# Проверить, что GOLOSNOWBOT_TOKEN установлен
grep GOLOSNOWBOT_TOKEN /root/Telegrambot/config/.env

# Проверить NOWCONTROLLERBOT_BROADCAST_BOTS
grep NOWCONTROLLERBOT_BROADCAST_BOTS /root/Telegrambot/config/.env
```

### 4. Создание бекапа базы данных (ОБЯЗАТЕЛЬНО!)

```bash
cd /root/Telegrambot

# Создать бекап базы данных
cp config/monetization.sqlite config/monetization.sqlite.backup_$(date +%Y%m%d_%H%M%S)

# Проверить, что бекап создан
ls -lh config/monetization.sqlite.backup_*
```

---

## 🗄️ Этап 1: Обновление базы данных (ДО обновления кода)

**Важно:** Обновление БД нужно делать ДО обновления кода и пересборки контейнеров, чтобы избежать конфликтов.

### SQL команды для выполнения:

```bash
cd /root/Telegrambot

sqlite3 config/monetization.sqlite <<EOF
-- Обновить имя бота в таблице sponsor_campaigns
UPDATE sponsor_campaigns 
SET bot_name = 'golosnowbot' 
WHERE bot_name = 'gsfortextbot';

-- Проверить результат
SELECT bot_name, COUNT(*) as count 
FROM sponsor_campaigns 
WHERE bot_name IN ('gsfortextbot', 'golosnowbot') 
GROUP BY bot_name;

-- Проверить bot_settings (если есть запись для gsfortextbot, обновить)
UPDATE bot_settings 
SET bot_name = 'golosnowbot' 
WHERE bot_name = 'gsfortextbot';

-- Проверить результат
SELECT bot_name, require_subscription, require_all_channels 
FROM bot_settings 
WHERE bot_name IN ('gsfortextbot', 'golosnowbot');
EOF
```

**Ожидаемый результат:**
- В `sponsor_campaigns` все записи с `gsfortextbot` должны стать `golosnowbot`
- В `bot_settings` запись для `golosnowbot` должна существовать (если была для `gsfortextbot`, она обновится)

---

## 📥 Этап 2: Обновление кода (через git pull или CI/CD)

### Вариант A: Через git pull (если нет CI/CD)

```bash
cd /root/Telegrambot

# Сохранить текущую ветку
git branch

# Получить последние изменения
git fetch origin

# Переключиться на нужную ветку (обычно main или master)
git checkout main  # или master

# Обновить код
git pull origin main  # или master

# Проверить, что изменения получены
git log --oneline -5
```

### Вариант B: Через CI/CD

Если используется CI/CD (GitHub Actions, GitLab CI и т.д.), код обновится автоматически после пуша в репозиторий.

**Важно:** После обновления кода проверь, что:
- Файл `docker-compose.prod.yml` содержит секцию `golosnowbot` (не `gsfortextbot`)
- Файл `config/.env` содержит `GOLOSNOWBOT_TOKEN` (не `GSFORTEXTBOT_TOKEN`)

---

## ⚙️ Этап 3: Обновление config/.env на VPS

```bash
cd /root/Telegrambot

# Проверить текущие значения
grep -E "GSFORTEXTBOT_TOKEN|GOLOSNOWBOT_TOKEN|NOWCONTROLLERBOT_BROADCAST_BOTS" config/.env

# Обновить NOWCONTROLLERBOT_BROADCAST_BOTS (если нужно)
# Было: NOWCONTROLLERBOT_BROADCAST_BOTS=...,gsfortextbot,...
# Стало: NOWCONTROLLERBOT_BROADCAST_BOTS=...,golosnowbot,...

# Убедиться, что GOLOSNOWBOT_TOKEN установлен (пользователь уже сделал это)
grep GOLOSNOWBOT_TOKEN config/.env
```

---

## 🐳 Этап 4: Остановка старых контейнеров

```bash
cd /root/Telegrambot

# Остановить и удалить старый контейнер gsfortextbot (если был запущен)
docker compose -f docker-compose.prod.yml stop gsfortextbot 2>/dev/null || echo "Контейнер gsfortextbot не найден"
docker compose -f docker-compose.prod.yml rm -f gsfortextbot 2>/dev/null || echo "Контейнер gsfortextbot не найден"

# Проверить, что контейнер удален
docker ps -a | grep gsfortextbot
```

---

## 🔨 Этап 5: Пересборка и запуск контейнеров

```bash
cd /root/Telegrambot

# Пересобрать образ golosnowbot
docker compose -f docker-compose.prod.yml build golosnowbot

# Запустить golosnowbot (он автоматически подождет nowcontrollerbot)
docker compose -f docker-compose.prod.yml up -d golosnowbot

# Проверить статус
docker compose -f docker-compose.prod.yml ps golosnowbot

# Проверить логи
docker compose -f docker-compose.prod.yml logs -f golosnowbot
```

**Ожидаемый результат в логах:**
```
[ INFO ] SaluteSpeech TLS: добавлены дополнительные корневые сертификаты из config/certs/salutespeech-chain.pem
[ INFO ] Monetization DB ensured at path (golosnowbot): config/monetization.sqlite
[ NOTICE ] Server started on http://0.0.0.0:8083
```

---

## 🔗 Этап 6: Настройка webhook

```bash
cd /root/Telegrambot

# Загрузить переменные окружения
set -a
source config/.env
set +a

# Настроить webhook для GolosNowBot
curl -X POST "https://api.telegram.org/bot${GOLOSNOWBOT_TOKEN}/setWebhook" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"https://nowbots.ru/golosnow/webhook\"}"

# Проверить webhook
curl "https://api.telegram.org/bot${GOLOSNOWBOT_TOKEN}/getWebhookInfo" | python3 -m json.tool
```

**Ожидаемый результат:**
```json
{
    "ok": true,
    "result": {
        "url": "https://nowbots.ru/golosnow/webhook",
        "pending_update_count": 0,
        "last_error_date": null,
        "last_error_message": null
    }
}
```

---

## ✅ Этап 7: Проверка работы

### 7.1 Проверка контейнера

```bash
# Проверить статус
docker compose -f docker-compose.prod.yml ps golosnowbot

# Проверить логи (должны быть без ошибок)
docker compose -f docker-compose.prod.yml logs --tail=50 golosnowbot

# Проверить, что контейнер слушает на порту 8083
docker exec telegrambot_golosnowbot netstat -tlnp | grep 8083 || \
docker exec telegrambot_golosnowbot ss -tlnp | grep 8083
```

### 7.2 Проверка Traefik

```bash
# Проверить, что Traefik видит golosnowbot
docker logs telegrambot_traefik 2>&1 | grep -i golosnow | tail -5

# Проверить доступность через Traefik
curl -I https://nowbots.ru/golosnow/webhook

# Должен вернуть HTTP/2 200 или 404 (но с HTTPS!)
```

### 7.3 Проверка webhook через Telegram

```bash
# Отправить тестовое сообщение боту в Telegram
# Бот должен ответить приветственным сообщением на /start
```

---

## 📋 Чеклист для миграции на VPS

### Перед обновлением кода
- [ ] Создан бекап базы данных
- [ ] Проверены текущие записи в БД (gsfortextbot/golosnowbot)
- [ ] Проверен config/.env (GOLOSNOWBOT_TOKEN установлен)

### Обновление базы данных
- [ ] Выполнены SQL миграции для sponsor_campaigns
- [ ] Выполнены SQL миграции для bot_settings (если нужно)
- [ ] Проверены результаты миграций

### Обновление кода
- [ ] Код обновлен через git pull или CI/CD
- [ ] Проверен docker-compose.prod.yml (секция golosnowbot)
- [ ] Проверен config/.env (NOWCONTROLLERBOT_BROADCAST_BOTS обновлен)

### Развертывание
- [ ] Старый контейнер gsfortextbot остановлен и удален
- [ ] Контейнер golosnowbot пересобран
- [ ] Контейнер golosnowbot запущен
- [ ] Webhook настроен и проверен
- [ ] Бот отвечает на /start в Telegram

---

## 🚨 Важные замечания

1. **Порядок выполнения:**
   - Сначала обновить БД
   - Потом обновить код
   - Потом пересобрать контейнеры
   - В конце настроить webhook

2. **Traefik автоматически подхватит изменения:**
   - После перезапуска контейнера golosnowbot
   - Traefik автоматически обнаружит новый сервис по labels
   - SSL сертификат будет работать автоматически

3. **База данных:**
   - БД находится на хосте: `/root/Telegrambot/config/monetization.sqlite`
   - Все контейнеры используют одну и ту же БД через volume mount
   - Бекап создается на хосте, не в контейнере

4. **Если что-то пошло не так:**
   ```bash
   # Восстановить БД из бекапа
   cp config/monetization.sqlite.backup_YYYYMMDD_HHMMSS config/monetization.sqlite
   
   # Откатить контейнер
   docker compose -f docker-compose.prod.yml stop golosnowbot
   docker compose -f docker-compose.prod.yml up -d gsfortextbot  # если нужно вернуться
   ```

---

## 📝 Команды для быстрого выполнения

```bash
# 1. Бекап БД
cd /root/Telegrambot && cp config/monetization.sqlite config/monetization.sqlite.backup_$(date +%Y%m%d_%H%M%S)

# 2. Обновление БД
sqlite3 config/monetization.sqlite "UPDATE sponsor_campaigns SET bot_name = 'golosnowbot' WHERE bot_name = 'gsfortextbot'; UPDATE bot_settings SET bot_name = 'golosnowbot' WHERE bot_name = 'gsfortextbot';"

# 3. Обновление кода (если через git)
git pull origin main

# 4. Остановка старого контейнера
docker compose -f docker-compose.prod.yml stop gsfortextbot && docker compose -f docker-compose.prod.yml rm -f gsfortextbot

# 5. Пересборка и запуск
docker compose -f docker-compose.prod.yml build golosnowbot
docker compose -f docker-compose.prod.yml up -d golosnowbot

# 6. Настройка webhook
set -a; source config/.env; set +a
curl -X POST "https://api.telegram.org/bot${GOLOSNOWBOT_TOKEN}/setWebhook" -H "Content-Type: application/json" -d "{\"url\":\"https://nowbots.ru/golosnow/webhook\"}"
```

---

**Дата создания:** 2025-01-24  
**Для миграции:** gsfortextbot → golosnowbot на VPS  
**Используется:** Traefik, Docker Compose
