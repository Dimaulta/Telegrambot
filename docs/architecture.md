# Архитектура проекта

## Обзор системы

Проект представляет собой микросервисную архитектуру для Telegram ботов с возможностью обработки видео и веб-интерфейсом.

## Компоненты системы

### 1. Core Server (Порт 8080)
**Назначение:** Основной сервер, точка входа для всех запросов

**Функции:**
- Проксирование webhook'ов к video-processing
- CORS поддержка для miniapp
- Статическая раздача файлов
- База данных SQLite для метаданных

**Файлы:**
- `core-server/Sources/App/routes.swift` — маршруты и прокси
- `core-server/Sources/App/configure.swift` — конфигурация сервера

### 2. Video Processing Service (Порт 8081)
**Назначение:** Обработка видео и miniapp интерфейс

**Функции:**
- Telegram miniapp для выбора области кропа
- Обработка видео через FFmpeg
- Создание видеокружков
- Прямая обработка видео из чата

**Файлы:**
- `Roundsvideobot/VideoService/Internal/VideoProcessor.swift` — обработка видео
- `Roundsvideobot/VideoService/Public/` — фронтенд miniapp
- `Roundsvideobot/VideoService/Internal/routes.swift` — API endpoints

### 3. Bot Services (Порты 8082–8084)
**Назначение:** Дополнительные боты

**Функции:**
- Независимые сервисы для новых ботов
- Готовые контроллеры и модели
- Настраиваемые webhook'и

**Структура:**
```
neurfotobot/
├── Sources/App/
│   ├── Controllers/
│   ├── Models/
│   ├── routes.swift
│   └── configure.swift
```

```
gsfortextbot/
├── Sources/App/
│   ├── Controllers/
│   ├── Models/
│   ├── routes.swift
│   └── configure.swift
```

## Потоки данных

### Обработка видео через miniapp
```
Пользователь → miniapp → /api/upload → VideoProcessor → Telegram API
```

### Прямая обработка видео
```
Пользователь → Telegram → /webhook → VideoProcessor → Telegram API
```

### Проксирование через core-server
```
Telegram → core-server/webhook → video-processing/webhook
```

## Конфигурация

### Переменные окружения
- `VIDEO_BOT_TOKEN` — токен видео-бота
- `NEURFOTOBOT_TOKEN` — токен бота для нейрофотографий
- `GSFORTEXTBOT_TOKEN` — токен бота для распознавания голоса
- `SORANOWBOT_TOKEN` — токен бота для удаления ватермарки Sora
- `BASE_URL` — базовый URL для webhook'ов

### Файлы конфигурации
- `config/server.json` — настройки сервера
- `config/services.json` — конфигурация сервисов
- `config/.env` — переменные окружения (создается пользователем)

## Технологический стек

- **Backend:** Swift + Vapor
- **Frontend:** HTML/CSS/JavaScript + Telegram Web App API
- **Обработка видео:** FFmpeg
- **База данных:** SQLite
- **Протокол:** HTTP/HTTPS

## Масштабирование

### Горизонтальное масштабирование
- Каждый сервис может быть развернут на отдельном сервере
- Использование load balancer для распределения нагрузки
- Независимое масштабирование компонентов

### Вертикальное масштабирование
- Увеличение ресурсов для обработки видео
- Оптимизация FFmpeg параметров
- Кэширование статических ресурсов

## Безопасность

### Аутентификация
- Токены ботов через переменные окружения
- Валидация webhook'ов от Telegram
- CORS настройки для miniapp

### Защита данных
- Временные файлы автоматически удаляются
- Ограничения на размер и длительность видео
- Валидация входных данных

## Мониторинг и логирование

### Логирование
- Структурированные логи через Swift Logging
- Отслеживание ошибок обработки
- Мониторинг производительности FFmpeg

### Метрики
- Время обработки видео
- Количество обработанных файлов
- Статистика ошибок
