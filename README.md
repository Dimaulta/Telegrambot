# Telegram Bot Services

Мультисервисная платформа для Telegram‑ботов с обработкой видео, распознаванием речи и внешними интеграциями.

## Статус проекта на 10 ноября 2025

- ✅ RoundsvideoBot — полностью готов
- ✅ NowmttBot — полностью готов
- ✅ GSforTextBot — полностью готов
- ⏳ Neurfotobot — в разработке / тестируется
- ❌ Wmmovebot — проект заморожен

## ⚠️ ВАЖНО: безопасность токенов

**ВНИМАНИЕ**: в истории коммитов ранее появились реальные токены. Все прежние токены заменены, но необходимо вручную создать `config/.env` и хранить там актуальные ключи.

Подробнее см. [docs/SECURITY.md](docs/SECURITY.md).

## Обзор

Проект состоит из набора независимых сервисов на Swift (Vapor) и вспомогательного Node.js микросервиса. Каждый бот разрабатывается и разворачивается отдельно, при этом ядро маршрутизирует входящие вебхуки и раздаёт мини‑приложение.

Для установки и запуска:
- [docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md) — подготовка окружения, зависимости и конфигурация (обновлён с шагами по SaluteSpeech).
- [docs/QUICK_START.md](docs/QUICK_START.md) — порядок запуска сервисов и проверок (обновлён с блоком про gsfortextbot).

## Сервисы и порты

| Сервис | Порт | Статус | Назначение |
| --- | --- | --- | --- |
| `core-server` | 8080 | Активен | Точка входа, проксирование webhook и статических ресурсов |
| `video-processing` (RoundsvideoBot) | 8081 | ✅ | Обработка видео, Telegram miniapp |
| `nowmttbot` | 8085 | ✅ | Загрузка TikTok‑видео без водяного знака |
| `gsfortextbot` | 8083 | ✅ | Распознавание голосовых сообщений в текст |
| `neurfotobot` | 8082 | ⏳ | AI‑обработка изображений (тестируется) |
| `wmmovebot` | 8084 | ❌ | Удаление ватермарки Sora (заморожен) |
| `playwright-service` | 3000 | ❌ | Chromium/Playwright для `wmmovebot` |

Детальное описание компонентов и потоков данных — в [docs/architecture.md](docs/architecture.md).

## Структура репозитория

```
Telegrambot/
├── config/                 # Конфигурация и скрипты развёртывания
├── core-server/            # Центральный сервер (Vapor)
├── Roundsvideobot/         # Видео-сервис и miniapp
├── nowmttbot/              # TikTok downloader
├── gsfortextbot/           # Распознавание речи
├── Neurfotobot/            # Обработка изображений (WIP)
├── wmmovebot/             # Замороженный сервис
├── playwright-service/     # Node.js сервис для браузерной автоматизации
└── docs/                   # Документация проекта
```

## Документация

- [SETUP_GUIDE.md](docs/SETUP_GUIDE.md) — установка и настройка окружения.
- [QUICK_START.md](docs/QUICK_START.md) — пошаговый запуск всех активных сервисов.
- [architecture.md](docs/architecture.md) — архитектура и статусы сервисов.
- [SECURITY.md](docs/SECURITY.md) — политика безопасности и работа с токенами.
- [gsfortextbot/docs/SETUP_PLAN.md](gsfortextbot/docs/SETUP_PLAN.md) — новое руководство: получение SaluteSpeech ключей, сертификатов и запуск бота.

## Лицензия

MIT License