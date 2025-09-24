# API Документация

## Video Processing Service API

### POST /api/upload
Загрузка и обработка видео через miniapp

**Request:**
- Content-Type: `multipart/form-data`
- Поля:
  - `video` (File) — видео файл
  - `chatId` (String) — ID чата
  - `cropData` (JSON String) — данные кропа

**cropData формат:**
```json
{
  "x": 0.5,
  "y": 0.5,
  "width": 0.3,
  "height": 0.3,
  "scale": 1.0
}
```

**Response:**
- Success: `200 OK` с сообщением "Видео успешно обработано и отправлено!"
- Error: `400 Bad Request` с описанием ошибки

### GET /
Отдает главную страницу miniapp

### GET /status
Отдает страницу статуса обработки (не используется в текущей версии)

## Core Server API

### POST /webhook
Webhook для Telegram ботов

**Request:**
- Content-Type: `application/json`
- Тело: стандартный Telegram Update объект

**Response:**
- `200 OK` — обработка успешна
- `400 Bad Request` — ошибка в данных
- `429 Too Many Requests` — уже обрабатывается другое видео

### GET /
Перенаправление на главную страницу

### GET /hello
Тестовый endpoint

## Template Bot Services API

### POST /webhook
Базовый webhook для шаблонных ботов

**Response:**
- `200 OK` — всегда успешно (заглушка)

## Telegram Bot API Integration

### Отправка сообщений
Все сервисы используют Telegram Bot API для отправки сообщений:

**Endpoint:** `https://api.telegram.org/bot{TOKEN}/sendMessage`

**Параметры:**
- `chat_id` — ID чата
- `text` — текст сообщения

### Отправка видеокружков
**Endpoint:** `https://api.telegram.org/bot{TOKEN}/sendVideoNote`

**Параметры:**
- `chat_id` — ID чата  
- `video_note` — файл видеокружка

## Статус-сообщения

### Для прямых загрузок видео
1. `🎬 Видео получено, ожидайте...` — после получения файла
2. `✅ Готово!` — перед отправкой кружка
3. `[видеокружок]` — финальный результат

### Для miniapp
Статусы отображаются в интерфейсе miniapp:
1. Видео загружается
2. Видео загружено  
3. Обработка видео
4. Создание кружка
5. Кружок в чате

## Обработка ошибок

### Коды ошибок
- `400 Bad Request` — неверные данные
- `413 Payload Too Large` — файл слишком большой
- `429 Too Many Requests` — уже обрабатывается видео
- `500 Internal Server Error` — ошибка сервера

### Типичные ошибки
- "Файл слишком большой" — размер > 100MB
- "Видео слишком длинное" — длительность > 60 секунд
- "Не удалось обработать видео" — ошибка FFmpeg
- "Не удалось отправить видеокружок" — ошибка Telegram API

## Rate Limiting

- Один пользователь может обрабатывать только одно видео одновременно
- Глобальный флаг `isProcessing` предотвращает параллельную обработку
- Автоматический сброс флага после завершения или ошибки

## CORS

Core Server настроен для поддержки CORS с параметрами:
- `allowedOrigin: .all`
- `allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH]`
- Специальный заголовок `ngrok-skip-browser-warning`
