# Vapor
Vapor server for backend telegram bots services (Swift)

# Что это такое
Готовый сервер на фреймворке Vapor для создания и развёртывания телеграм ботов написанных на Swift
В качестве примера написан бот по обработки пользовательских видео в стандартный видеокружок

# Конфигурация серверов и сервисов

## ⚠️ ВАЖНО: Настройка токенов

**ОБЯЗАТЕЛЬНО создайте файл `config/.env` перед запуском сервисов!**

Скопируйте `config/env.example` в `config/.env` и добавьте ваши токены:

```env
# БАЗОВЫЕ URL
BASE_URL=https://your-domain.com

# ТОКЕНЫ БОТОВ
VIDEO_BOT_TOKEN=YOUR_BOT_TOKEN
TELEGRAMBOT03_TOKEN=YOUR_BOT03_TOKEN
TELEGRAMBOT04_TOKEN=YOUR_BOT04_TOKEN
```

В этом каталоге находятся файлы конфигурации:
- `server.json` — базовые параметры публичного сервера.
- `services.json` — список внутренних сервисов и их адресов.
- `.env` — переменные окружения с токенами (создается пользователем).
- `env.example` — шаблон для создания `.env` файла.

## Что менять после покупки домена

1) protocol
- Если подключён валидный TLS‑сертификат — оставь `https`.
- Временно без TLS — укажи `http` (не рекомендуется для продакшена).

2) base_url
- Замени на `https://твой-домен` без указания `:443`.
- Примеры: `https://example.com`, `https://api.example.com`.

3) ip
- Можно оставить текущий IP или `0.0.0.0` — это не критично для внешнего URL.
- Главный источник правды для внешних ссылок — `base_url`.

4) port
- За балансировщиком/прокси обычно внешний порт 443. В `base_url` 443 писать не нужно.
- Внутренние сервисы продолжают слушать свои локальные порты (см. `services.json`).

## services.json
- Для каждого сервиса есть поле `url` вида `http://localhost:PORT` — это внутренняя точка.
- Поле `webhook_url` — внешний URL, куда Telegram будет слать вебхуки. Подставь домен.

## Быстрый чек‑лист
- [ ] Создан файл `config/.env` с токенами ботов
- [ ] Настроен TLS и домен
- [ ] `server.json` → `protocol=https`, `base_url=https://твой-домен`
- [ ] `services.json` → `webhook_url` указывает на `https://твой-домен/<route>`
- [ ] Прокси (nginx/caddy) пробрасывает к нужному сервису
- [ ] Настроены webhook'и для всех ботов

# Для локальной отладки и разработки понадобится Ngrock (https://dashboard.ngrok.com), необходимо зарегистрироваться в сервисе и установить его локально
он выдаёт вам рабочий URL который надо прописывать в Botfather для miniapp и по короткому гайду ниже:
(учтите что приведённые ниже токены и URL уже заменены и вам надо подстввить свои)

Полный гайд по запуску и отладке моего пет проекта на Vapor
Первый проект это телеграм бот по обрезанию всех входящих в него видео до стандартного телеграм кружка
Все примеры делаются на временном Ngrock домене (у вас он будет другой) https://db6e2646e62b.ngrok-free.app:

1. В терминале запустить 
ngrok http 8081 --log=stdout

2. Скопировать туннель в буфер обмена, он будет выглядеть примерно так:
https://db6e2646e62b.ngrok-free.app

3. Вставить в файл config/server.json на строчку 6 свой url (ниже пример), должно получиться:
    "base_url": "https://db6e2646e62b.ngrok-free.app"

4. В терминале в новой вкладке Cmd + T запустить крманду с учётом адреса до папки с проектом (у вас другой адрес):
cd /Users/a1111/Desktop/projects/telegrambot01 && LOG_LEVEL=debug swift run VideoServiceRunner

5.1 Сброс вебхука (у вас будет другой токен бота, этот уже не актуален)
curl -s -X POST "https://api.telegram.org/bot7901916114:AAHi5csiMOi7fgL0c1TzRRc_V1eibq_9d-E/deleteWebhook?drop_pending_updates=true"

5.2 Установить вебхук (у вас будет другой токен бота, этот уже не актуален)
curl -X POST "https://api.telegram.org/bot7901916114:AAHi5csiMOi7fgL0c1TzRRc_V1eibq_9d-E/setWebhook" -H "Content-Type: application/json" -d '{"url": "https://db6e2646e62b.ngrok-free.app/webhook"}'

5.3 Проверить установлен ли вебхук (у вас будет другой токен бота, этот уже не актуален)
curl -s "https://api.telegram.org/bot7901916114:AAHi5csiMOi7fgL0c1TzRRc_V1eibq_9d-E/getWebhookInfo"


6. В @botfather выбрать @roundvideobot и далее в "Menu button" нажать "Configure menu button" и вставить URL из Ngrock или купленного домена

Это всё!
