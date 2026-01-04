# AntispamNowBot

Черновой каркас Telegram-бота для антиспама. Бот будет выполнять функции выключателя на ночь, капчи для вступления и запрещателя сообщений от каналов.

## Что подготовлено
- Создано Vapor-приложение с точки входа, маршрутом `POST /webhook` и `GET /health`.
- Добавлены шаблонные контроллер, модели и сервис для планирования антиспам функций.
- Оставлены подсказки `TODO` для реализации функций антиспама.

## Следующие шаги
1. Зарегистрировать бота у BotFather и сохранить токен в `config/.env` (`ANTISPAMNOWBOT_TOKEN`).
2. Указать порт при необходимости (`ANTISPAMNOWBOT_PORT`, по умолчанию 8088).
3. Убедиться, что вебхук проброшен на `${BASE_URL}/antispamnow/webhook` (см. `config/services.json` и nginx-конфиг в `docs/SETUP_GUIDE.md`).
4. Реализовать функции антиспама в `AntispamNowBot/Sources/App/Services/AntiSpamService.swift`.
5. Написать сценарии и тесты для обработки разных типов запросов (ночной режим, капча, блокировка каналов).

## Запуск
```bash
cd /Users/a1111/Desktop/projects/Telegrambot
swift run AntispamNowBot
```


