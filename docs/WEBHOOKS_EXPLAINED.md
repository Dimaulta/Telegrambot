# 📡 Webhooks - что это и как настроить

## 🤔 Что такое Webhook?

**Webhook** - это URL адрес, куда Telegram отправляет все сообщения и события от пользователей твоих ботов.

### Как это работает:

```
Пользователь → Telegram → Webhook URL → Твой бот
```

**Пример:**
1. Пользователь пишет боту `/start`
2. Telegram отправляет это сообщение на webhook URL (например: `https://nowbots.ru/neurfoto/webhook`)
3. Твой бот получает сообщение и обрабатывает его
4. Бот отвечает пользователю

## 📋 Что указывается в Webhook?

**Полный URL с доменом и путем!**

Формат:
```
https://nowbots.ru/<путь>/webhook
```

**Примеры для разных ботов:**
- Neurfotobot: `https://nowbots.ru/neurfoto/webhook`
- NowmttBot: `https://nowbots.ru/nowmtt/webhook`
- Roundsvideobot: `https://nowbots.ru/rounds/webhook`
- GSForTextBot: `https://nowbots.ru/gs/text/webhook`
- ContentFabrikaBot: `https://nowbots.ru/contentfabrika/webhook`
- PereskazNowBot: `https://nowbots.ru/pereskaznow/webhook`
- NowControllerBot: `https://nowbots.ru/nowcontroller/webhook`

## ✅ Нужно ли обновлять Webhooks?

### Да, нужно обновить после первого запуска!

**Когда обновлять:**
1. ✅ После первого запуска контейнеров на VPS
2. ✅ Если изменился `BASE_URL` в `.env`
3. ✅ Если изменились пути в `docker-compose.prod.yml`

**Когда НЕ нужно обновлять:**
- ❌ При перезапуске контейнеров (webhook URL не меняется)
- ❌ При обновлении кода ботов (URL остается прежним)
- ❌ При обычной работе (URL постоянный)

## 🚀 Как обновить Webhooks?

### Способ 1: Автоматический (рекомендуется)

Есть готовый скрипт который обновит все webhooks сразу:

```bash
cd /root/Telegrambot
set -a; source config/.env; set +a
./config/set-webhooks.sh
```

**Что делает скрипт:**
- Читает `BASE_URL` из `config/.env`
- Для каждого бота отправляет POST запрос в Telegram API
- Устанавливает webhook URL автоматически
- Показывает результат для каждого бота

### Способ 2: Вручную через Telegram API

Для одного бота:

```bash
# Замени TOKEN на токен бота, URL на нужный путь
curl -X POST "https://api.telegram.org/bot<TOKEN>/setWebhook" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://nowbots.ru/neurfoto/webhook"}'
```

**Пример для Neurfotobot:**
```bash
curl -X POST "https://api.telegram.org/bot${NEURFOTOBOT_TOKEN}/setWebhook" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://nowbots.ru/neurfoto/webhook"}'
```

### Способ 3: Через @BotFather (не рекомендуется)

Можно установить webhook через @BotFather, но это неудобно для множества ботов.

## 🔍 Как проверить что Webhook установлен?

### Через скрипт:

Скрипт `set-webhooks.sh` автоматически проверяет webhook после установки.

### Вручную:

```bash
# Замени TOKEN на токен бота
curl "https://api.telegram.org/bot<TOKEN>/getWebhookInfo"
```

**Пример ответа:**
```json
{
  "ok": true,
  "result": {
    "url": "https://nowbots.ru/neurfoto/webhook",
    "has_custom_certificate": false,
    "pending_update_count": 0
  }
}
```

## 📝 Что нужно проверить перед обновлением?

1. ✅ **BASE_URL в .env правильный:**
   ```env
   BASE_URL=https://nowbots.ru
   ```
   (не IP адрес, а домен!)

2. ✅ **Контейнеры запущены:**
   ```bash
   docker compose -f docker-compose.prod.yml ps
   ```
   Все боты должны быть в статусе `Up`

3. ✅ **Traefik работает:**
   ```bash
   docker compose -f docker-compose.prod.yml logs traefik | tail -20
   ```
   Должен быть SSL сертификат получен

4. ✅ **HTTPS доступен:**
   ```bash
   curl -I https://nowbots.ru/neurfoto/webhook
   ```
   Должен вернуть HTTP/2 200 или 404 (но с HTTPS!)

## ⚠️ Важные моменты

### 1. Обязательно HTTPS!

Telegram требует HTTPS для webhooks. HTTP не работает!

✅ Правильно: `https://nowbots.ru/neurfoto/webhook`
❌ Неправильно: `http://nowbots.ru/neurfoto/webhook`

### 2. Домен, а не IP!

Telegram не принимает IP адреса для webhooks.

✅ Правильно: `https://nowbots.ru/neurfoto/webhook`
❌ Неправильно: `https://85.208.110.226/neurfoto/webhook`

### 3. Путь должен совпадать с docker-compose

Путь в webhook URL должен совпадать с `PathPrefix` в labels Traefik:

```yaml
# docker-compose.prod.yml
- "traefik.http.routers.neurfotobot.rule=Host(`nowbots.ru`) && PathPrefix(`/neurfoto/webhook`)"
```

Webhook URL: `https://nowbots.ru/neurfoto/webhook` ✅

## 🎯 Итоговая инструкция

### После запуска контейнеров:

1. **Проверь что контейнеры запущены:**
   ```bash
   docker compose -f docker-compose.prod.yml ps
   ```

2. **Проверь что HTTPS работает:**
   ```bash
   curl -I https://nowbots.ru/neurfoto/webhook
   ```

3. **Обнови webhooks:**
   ```bash
   cd /root/Telegrambot
   set -a; source config/.env; set +a
   ./config/set-webhooks.sh
   ```

4. **Проверь что webhooks установлены:**
   Скрипт покажет результат для каждого бота.

## ✅ Готово!

После этого все боты будут получать сообщения от Telegram через webhooks! 🚀

