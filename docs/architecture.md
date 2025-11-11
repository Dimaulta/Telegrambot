# Архитектура проекта

## Обзор системы

Проект представляет собой микросервисную архитектуру для Telegram ботов с возможностью обработки видео и веб-интерфейсом.

### Статус разработки

- ✅ **MVP (2 бота):**
  - `Roundsvideobot` — обработка видео в видеокружки с miniapp интерфейсом
  - `nowmttbot` — скачивание TikTok видео без водяного знака

- ❄️ **Заморожен (1 бот):**
  - `wmmovebot` — удаление ватермарки с видео Sora (документация по разморозке в `wmmovebot/docs/`)

- ⏸️ **Не начаты (2 бота):**
  - `gsfortextbot` — расшифровка голосовых сообщений в текст
  - `Neurfotobot` — обработка изображений через AI

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

### 3. Playwright Service (Порт 3000) ❄️
**Назначение:** Микросервис на Node.js для получения HTML страниц с JavaScript-рендерингом

**Статус:** Используется замороженным проектом `wmmovebot`

**Функции:**
- Запуск реального браузера (Chromium) в headless режиме
- Получение HTML страниц с выполненным JavaScript
- Извлечение данных из `__NEXT_DATA__` для Sora страниц
- Использование persistent профиля браузера (сохранение куков)

**Технологии:**
- Node.js
- Playwright
- Docker

**Файлы:**
- `playwright-service/index.js` — основной сервер
- `playwright-service/Dockerfile` — конфигурация Docker
- `playwright-service/browser-profile/` — профиль браузера с куками

### 4. Bot Services

#### 4.1. NowmttBot (Порт 8082) ✅ **MVP**
**Статус:** Доведен до MVP, работает в продакшене

**Назначение:** Бот для скачивания TikTok видео без водяного знака

**Функции:**
- Извлечение прямых ссылок на TikTok видео
- Отправка видео пользователю через Telegram API
- Обработка различных форматов TikTok URL (vm.tiktok.com, tiktok.com, vt.tiktok.com)

**Файлы:**
- `nowmttbot/Sources/App/Controllers/NowmttBotController.swift` — основной контроллер
- `nowmttbot/Sources/App/Internal/TikTokResolver.swift` — резолвер TikTok ссылок
- `nowmttbot/Sources/App/Middleware/LoggingMiddleware.swift` — логирование

#### 4.2. WmmoveBot (Порт 8084) ❄️ **Заморожен**
**Статус:** Проект временно заморожен, документация по разморозке в `wmmovebot/docs/`

**Назначение:** Бот для удаления ватермарки с видео Sora

**Функции:**
- Получение HTML страниц Sora через Playwright сервис
- Извлечение данных из `__NEXT_DATA__`
- Обработка видео для удаления ватермарки

**Структура:**
```
wmmovebot/
├── Sources/App/
│   ├── Controllers/
│   ├── Models/
│   ├── Middleware/
│   └── routes.swift
└── docs/                    # Документация по разморозке проекта
    ├── PLAN_NEXT.md
    ├── ALTERNATIVE_METHODS.md
    └── ALTERNATIVE_SOLUTIONS.md
```

**Зависимости:**
- `playwright-service` — микросервис на Node.js для получения HTML с JavaScript-рендерингом

#### 4.3. GSForTextBot (Порт 8083) ⏸️ **Не начат**
**Статус:** Только базовая структура, разработка не начата

**Планируемое назначение:** Расшифровка голосовых сообщений в текст

**Текущее состояние:**
- Базовая структура проекта создана
- Контроллер содержит только заглушку
- Функциональность не реализована

**Структура:**
```
gsfortextbot/
├── Sources/App/
│   ├── Controllers/
│   ├── Models/
│   ├── routes.swift
│   └── configure.swift
```

**Документация:** подробный план интеграции SaluteSpeech — `gsfortextbot/docs/SETUP_PLAN.md`.

#### 4.4. Neurfotobot (Порт 8082) ⏸️ **Не начат**
**Статус:** Только базовая структура, разработка не начата

**Планируемое назначение:** Бот для нейрофотографий (AI обработка изображений)

**Текущее состояние:**
- Базовая структура проекта создана
- Контроллер содержит только заглушку
- Функциональность не реализована

**Структура:**
```
Neurfotobot/
├── Sources/App/
│   ├── Controllers/
│   ├── Models/
│   ├── routes.swift
│   └── configure.swift
```

## Потоки данных

### Обработка видео через miniapp (Roundsvideobot)
```
Пользователь → miniapp → /api/upload → VideoProcessor → Telegram API
```

### Прямая обработка видео (Roundsvideobot)
```
Пользователь → Telegram → /webhook → VideoProcessor → Telegram API
```

### Проксирование через core-server (Roundsvideobot)
```
Telegram → core-server/webhook → video-processing/webhook
```

### Обработка TikTok видео (nowmttbot)
```
Пользователь → Telegram → /webhook → NowmttBotController → TikTokResolver → Telegram API
```

**Процесс:**
1. Пользователь отправляет TikTok ссылку боту
2. Контроллер извлекает URL из сообщения
3. TikTokResolver получает прямую ссылку на видео
4. Видео отправляется пользователю через Telegram API

## Конфигурация

### Переменные окружения

**Обязательные (для работающих ботов):**
- `VIDEO_BOT_TOKEN` — токен видео-бота (Roundsvideobot) ✅
- `NOWMTTBOT_TOKEN` — токен бота для TikTok видео ✅
- `BASE_URL` — базовый URL для webhook'ов

**Опциональные (для замороженных/не начатых ботов):**
- `WMMOVEBOT_TOKEN` — токен бота для удаления ватермарки Sora ❄️
- `GSFORTEXTBOT_TOKEN` — токен бота для распознавания голоса ⏸️
- `NEURFOTOBOT_TOKEN` — токен бота для нейрофотографий ⏸️

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
- **Браузерная автоматизация (wmmovebot):** Node.js + Playwright
- **Контейнеризация:** Docker, Docker Compose

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
