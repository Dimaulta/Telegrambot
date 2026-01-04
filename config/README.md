# Конфигурация серверов и сервисов

## ⚠️ ВАЖНО: Настройка токенов

**ОБЯЗАТЕЛЬНО создайте файл `config/.env` перед запуском сервисов!**

Скопируйте `docs/env.example` в `config/.env` и добавьте ваши токены:

```env
# БАЗОВЫЕ URL
BASE_URL=https://your-domain.com

# ТОКЕНЫ БОТОВ
VIDEO_BOT_TOKEN=YOUR_BOT_TOKEN
NEURFOTOBOT_TOKEN=YOUR_NEURFOTOBOT_TOKEN
GSFORTEXTBOT_TOKEN=YOUR_GSFT_TOKEN
NOWCONTROLLERBOT_TOKEN=YOUR_NOWCONTROLLER_TOKEN
ANTISPAMNOWBOT_TOKEN=YOUR_ANTISPAMNOW_TOKEN
GOLOSNOWBOT_TOKEN=YOUR_GOLOSNOW_TOKEN
NEURVIDEOBOT_TOKEN=YOUR_NEURVIDEO_TOKEN
```

В этом каталоге находятся файлы конфигурации:
- `server.json` — базовые параметры публичного сервера.
- `services.json` — список внутренних сервисов и их адресов.
- `.env` — переменные окружения с токенами (создается пользователем).
- `docs/env.example` — шаблон для создания `.env` файла (находится в папке docs).

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
