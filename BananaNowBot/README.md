# BananaNowBot

Черновой каркас Telegram-бота для сервиса **Nano Banana**. Бот будет принимать текстовое описание от пользователя и возвращать результат в формате изображения, отредактированного изображения или видео.

## Что подготовлено
- Создано Vapor-приложение с точки входа, маршрутом `POST /webhook` и `GET /health`.
- Добавлены шаблонные контроллер, модели и сервис для планирования генерации/редактирования медиа по тексту.
- Оставлены подсказки `TODO` для интеграции с внешним API Nano Banana и Telegram.

## Следующие шаги
1. Зарегистрировать бота у BotFather и сохранить токен в `config/.env` (`BANANANOWBOT_TOKEN`).
2. Указать ключ Nano Banana (`BANANANOWBOT_NANO_API_KEY`) и при необходимости порт (`BANANANOWBOT_PORT`, по умолчанию 8088).
3. Убедиться, что вебхук проброшен на `${BASE_URL}/banananow/webhook` (см. `config/services.json` и nginx-конфиг в `docs/SETUP_GUIDE.md`).
4. Реализовать интеграцию с Nano Banana API в `BananaNowBot/Sources/App/Services/BananaNowMediaService.swift`.
5. Написать сценарии и тесты для обработки разных типов запросов (изображение, редактирование, видео).

## Запуск
```bash
cd /Users/a1111/Desktop/projects/Telegrambot
swift run BananaNowBot
```


