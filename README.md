# Telegram Bot Services

Мультисервисная платформа для Telegram ботов с видеообработкой и miniapp интерфейсом.

## ⚠️ ВАЖНО: Безопасность токенов

**ВНИМАНИЕ**: В истории коммитов этого репозитория ранее содержались реальные токены ботов в открытом виде. Все токены были заменены на новые. 

**ОБЯЗАТЕЛЬНО** создайте файл `config/.env` с вашими токенами перед запуском сервисов.

## 🚀 Быстрый старт

### 1. Настройка переменных окружения

Создайте файл `config/.env` с содержимым:

```env
# БАЗОВЫЕ URL
BASE_URL=https://your-domain.com

# ТОКЕНЫ БОТОВ
VIDEO_BOT_TOKEN=YOUR_BOT_TOKEN
TELEGRAMBOT03_TOKEN=YOUR_BOT03_TOKEN
TELEGRAMBOT04_TOKEN=YOUR_BOT04_TOKEN
```

**Где получить токены:**
1. Откройте [@BotFather](https://t.me/botfather) в Telegram
2. Создайте новых ботов командой `/newbot`
3. Скопируйте полученные токены в `config/.env`

### 2. Запуск сервисов

```bash
# Запуск основного сервера (core-server)
swift run App

# Запуск видео-сервиса (в отдельном терминале)
swift run VideoServiceRunner

# Запуск дополнительных ботов (опционально)
swift run telegrambot03
swift run telegrambot04
```

### 3. Настройка webhook

После запуска сервисов настройте webhook для вашего бота:

```bash
# Замените YOUR_BOT_TOKEN на реальный токен
curl -X POST "https://api.telegram.org/botYOUR_BOT_TOKEN/setWebhook" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://your-domain.com/webhook"}'
```

## 🏗️ Архитектура

Проект состоит из нескольких независимых сервисов:

- **core-server** (порт 8080) — основной сервер с проксированием
- **video-processing** (порт 8081) — обработка видео и miniapp
- **telegrambot03** (порт 8083) — шаблон для дополнительного бота
- **telegrambot04** (порт 8084) — шаблон для дополнительного бота

### Схема взаимодействия

```
Telegram → core-server → video-processing (прокси)
                ↓
        telegrambot03/04 (независимые сервисы)
```

## 📁 Структура проекта

```
telegrambot01/
├── config/
│   ├── .env                    # Ваши токены (создать самостоятельно)
│   ├── server.json             # Настройки сервера
│   ├── services.json           # Конфигурация сервисов
│   └── README.md               # Детальная настройка конфигов
├── core-server/                # Основной сервер
├── Roundsvideobot/             # Видео-сервис с miniapp
├── telegrambot03/              # Шаблон бота #3
├── telegrambot04/              # Шаблон бота #4
└── docs/                       # Документация
```

## 🎬 Функциональность

### Video Bot (video-processing)
- Обработка видео в видеокружки
- Telegram miniapp для выбора области кропа
- Прямая загрузка видео в чат
- Статус-сообщения о прогрессе обработки

### Core Server
- Проксирование запросов к video-processing
- Единая точка входа для webhook'ов
- CORS поддержка для miniapp

## 🔧 Конфигурация

### config/server.json
```json
{
  "server": {
    "ip": "0.0.0.0",
    "port": 8080,
    "protocol": "https",
    "base_url": "https://your-domain.com"
  }
}
```

### config/services.json
```json
{
  "services": {
    "video-processing": {
      "url": "http://localhost:8081",
      "webhook_url": "${BASE_URL}/webhook"
    }
  }
}
```

## 🌐 Развертывание

### Локальная разработка с ngrok
1. Установите [ngrok](https://ngrok.com/)
2. Запустите туннель: `ngrok http 8081`
3. Обновите `base_url` в `config/server.json`
4. Создайте `config/.env` с токенами
5. Запустите сервисы

### Продакшен
1. Настройте домен и SSL сертификат
2. Обновите `config/server.json` с вашим доменом
3. Настройте nginx/caddy для проксирования
4. Установите webhook'и для ботов

## 📚 Дополнительная документация

- [Настройка конфигурации](config/README.md)
- [Архитектура сервисов](docs/architecture.md)
- [API документация](docs/api.md)
- [Развертывание](docs/deployment.md)

## 🔒 Безопасность

- Все токены хранятся в `config/.env` (не коммитятся в git)
- Используйте HTTPS для продакшена
- Регулярно обновляйте токены ботов
- Не публикуйте реальные токены в открытом доступе

## 🤝 Поддержка

При возникновении проблем:
1. Проверьте, что `config/.env` создан и содержит правильные токены
2. Убедитесь, что все сервисы запущены
3. Проверьте логи сервисов на наличие ошибок
4. Убедитесь, что webhook настроен правильно

## 📄 Лицензия

MIT License