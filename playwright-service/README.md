# Playwright Service для WmmoveBot

Микросервис на Node.js + Playwright для получения HTML страниц Sora с `__NEXT_DATA__`.

## Что делает

- Запускает реальный браузер (Chromium) в headless режиме
- Открывает страницы Sora и ждёт загрузки `__NEXT_DATA__`
- Возвращает HTML с JavaScript-рендерингом
- Использует persistent профиль браузера (куки сохраняются)

## Запуск через Docker

### Локальная разработка

```bash
# Собрать образ
docker compose build playwright-service

# Запустить сервис
docker compose up playwright-service

# Или в фоне
docker compose up -d playwright-service
```

### Проверка работы

```bash
# Health check
curl http://localhost:3000/health

# Получить HTML страницы
curl -X POST http://localhost:3000/fetch \
  -H "Content-Type: application/json" \
  -d '{"url": "https://sora.chatgpt.com/p/s_68eaaa225d1c8191909f343ab01bb3fa"}'
```

## API

### POST /fetch

Получить HTML страницы с `__NEXT_DATA__`.

**Request:**
```json
{
  "url": "https://sora.chatgpt.com/p/s_68eaaa225d1c8191909f343ab01bb3fa"
}
```

**Response:**
```json
{
  "success": true,
  "html": "<html>...</html>",
  "hasNextData": true,
  "length": 123456
}
```

### GET /health

Проверка статуса сервиса.

## Особенности

- **Persistent профиль**: Куки и кэш сохраняются в `browser-profile/`
- **Блокировка медиа**: Не загружает изображения, видео, шрифты (экономия трафика)
- **Автоматическое ожидание**: Ждёт загрузки `__NEXT_DATA__` до 30 секунд
- **Ограничение памяти**: 2GB максимум на контейнер

## Удаление

Если нужно удалить всё:

```bash
# Остановить и удалить контейнер
docker compose down playwright-service

# Удалить образ
docker rmi telegrambot-playwright-service

# Удалить папку с профилем (если нужно)
rm -rf browser-profile/
```

