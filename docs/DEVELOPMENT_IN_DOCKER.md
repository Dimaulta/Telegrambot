# 🐳 Разработка в Docker

## 📋 Обзор

Этот документ описывает, как разрабатывать проект локально в Docker, чтобы избежать проблем при деплое на Linux сервер.

## 🎯 Зачем это нужно?

**Проблема:**
- Разработка на macOS → код использует macOS-специфичные пути и функции
- Деплой на Linux → код не работает или работает по-другому
- SQLite базы создаются на Mac → формат может отличаться

**Решение:**
- Разработка в Docker контейнере (Linux окружение)
- Код редактируешь на Mac в IDE (удобно)
- Запуск происходит в Linux контейнере (как на сервере)
- Окружение одинаковое → проблем нет

## 🏗️ Как это работает?

```
┌─────────────────────────────────────────┐
│  Mac (твой компьютер)                    │
│  ┌───────────────────────────────────┐   │
│  │  IDE                              │   │
│  │  (редактируешь код здесь)         │   │
│  └───────────────────────────────────┘   │
│           ↓ (volumes)                    │
│  ┌───────────────────────────────────┐   │
│  │  Docker контейнер (Linux)         │   │
│  │  ┌─────────────────────────────┐  │   │
│  │  │  Swift код запускается здесь │  │   │
│  │  │  (swift run)                 │  │   │
│  │  └─────────────────────────────┘  │   │
│  └───────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

**Ключевые моменты:**
1. **Код на Mac** → редактируешь в IDE как обычно
2. **Volumes** → Docker монтирует папки с кодом в контейнер
3. **Запуск в контейнере** → `swift run` выполняется в Linux окружении
4. **Окружение одинаковое** → как на сервере, так и локально

## 📁 Структура файлов

```
Telegrambot/
├── docker-compose.dev.yml    # ← Новый файл для разработки
├── docker-compose.prod.yml   # ← Для продакшена (уже есть)
├── Dockerfile.dev            # ← Новый Dockerfile для разработки
└── ...
```

## 🚀 Быстрый старт

### 1. Создай файл `docker-compose.dev.yml`

См. раздел "Конфигурация" ниже.

### 2. Запусти сервис для разработки

```bash
# Запустить один сервис (например, Neurfotobot)
docker compose -f docker-compose.dev.yml up neurfotobot

# Запустить все сервисы
docker compose -f docker-compose.dev.yml up

# Запустить в фоне
docker compose -f docker-compose.dev.yml up -d
```

### 3. Редактируй код в IDE

- Открывай файлы как обычно
- Редактируй код
- Сохраняй изменения

### 4. Перезапусти контейнер для применения изменений

```bash
# Остановить
docker compose -f docker-compose.dev.yml stop neurfotobot

# Запустить снова
docker compose -f docker-compose.dev.yml up neurfotobot
```

Или используй hot-reload (см. раздел "Hot Reload" ниже).

## ⚙️ Конфигурация

### docker-compose.dev.yml

```yaml
version: '3.8'

# Docker Compose для разработки
# Использование: docker compose -f docker-compose.dev.yml up

services:
  # NowControllerBot
  nowcontrollerbot:
    build:
      context: .
      dockerfile: Dockerfile.dev
      args:
        PRODUCT: NowControllerBot
    container_name: telegrambot_dev_nowcontrollerbot
    restart: unless-stopped
    env_file:
      - config/.env
    environment:
      - LOG_LEVEL=debug
    volumes:
      # Монтируем код для разработки
      - .:/app
      # Монтируем config отдельно
      - ./config:/app/config
    working_dir: /app
    command: swift run NowControllerBot serve --hostname 0.0.0.0 --port 8084
    ports:
      - "8084:8084"
    networks:
      - telegrambot_dev_network

  # Neurfotobot
  neurfotobot:
    build:
      context: .
      dockerfile: Dockerfile.dev
      args:
        PRODUCT: Neurfotobot
    container_name: telegrambot_dev_neurfotobot
    restart: unless-stopped
    env_file:
      - config/.env
    environment:
      - LOG_LEVEL=debug
    volumes:
      - .:/app
      - ./config:/app/config
      - ./Neurfotobot:/app/Neurfotobot
    working_dir: /app
    command: swift run Neurfotobot serve --hostname 0.0.0.0 --port 8082
    ports:
      - "8082:8082"
    networks:
      - telegrambot_dev_network
    depends_on:
      - nowcontrollerbot

  # Roundsvideobot
  roundsvideobot:
    build:
      context: .
      dockerfile: Dockerfile.dev
      args:
        PRODUCT: VideoServiceRunner
    container_name: telegrambot_dev_roundsvideobot
    restart: unless-stopped
    env_file:
      - config/.env
    environment:
      - LOG_LEVEL=debug
    volumes:
      - .:/app
      - ./config:/app/config
      - ./Roundsvideobot/Resources/temporaryvideoFiles:/app/Roundsvideobot/Resources/temporaryvideoFiles
    working_dir: /app
    command: swift run VideoServiceRunner serve --hostname 0.0.0.0 --port 8081
    ports:
      - "8081:8081"
    networks:
      - telegrambot_dev_network
    depends_on:
      - nowcontrollerbot

  # Добавь остальные сервисы по аналогии...

networks:
  telegrambot_dev_network:
    driver: bridge
```

### Dockerfile.dev

```dockerfile
# Dockerfile для разработки
# Использует swift:6.0-noble для разработки (не production build)

FROM swift:6.0-noble

# Build argument для указания продукта
ARG PRODUCT=App

# Install зависимости
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y \
      libjemalloc-dev \
      curl \
      libsqlite3-dev \
      ffmpeg \
      python3 \
      python3-pip \
      wget \
    && pip3 install --no-cache-dir --break-system-packages yt-dlp \
    && wget -qO /usr/local/bin/yt-dlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
    && chmod a+rx /usr/local/bin/yt-dlp \
    && rm -r /var/lib/apt/lists/*

# Рабочая директория
WORKDIR /app

# Копируем Package.swift для разрешения зависимостей
COPY Package.swift Package.resolved* ./

# Разрешаем зависимости (кэшируется если Package.swift не изменился)
RUN swift package resolve

# Код будет монтироваться через volume, поэтому не копируем его здесь
# Это позволяет редактировать код на Mac и видеть изменения в контейнере

# По умолчанию запускаем swift run (переопределяется в docker-compose)
CMD ["swift", "run", "NowControllerBot"]
```

## 🔄 Workflow разработки

### Вариант 1: Ручной перезапуск (простой)

1. **Редактируй код в IDE**
2. **Сохраняй файлы**
3. **Перезапускай контейнер:**
   ```bash
   docker compose -f docker-compose.dev.yml restart neurfotobot
   ```

### Вариант 2: Hot Reload (автоматический)

Используй `swift run` с флагом `--watch` (если поддерживается) или используй внешний инструмент типа `watchexec`:

```yaml
# В docker-compose.dev.yml
command: watchexec -w Sources -- swift run Neurfotobot serve --hostname 0.0.0.0 --port 8082
```

Или используй Vapor's built-in watch mode (если доступен).

## 🧪 Тестирование

### Локальное тестирование

1. **Запусти сервисы:**
   ```bash
   docker compose -f docker-compose.dev.yml up
   ```

2. **Настрой ngrok** (на Mac, не в контейнере):
   ```bash
   ngrok http 8080
   ```

3. **Настрой webhooks:**
   ```bash
   set -a; source config/.env; set +a
   ./config/set-webhooks.sh
   ```

4. **Тестируй бота** через Telegram

### Проверка логов

```bash
# Все логи
docker compose -f docker-compose.dev.yml logs -f

# Конкретный сервис
docker compose -f docker-compose.dev.yml logs -f neurfotobot
```

## 📂 Работа с временными файлами

### Roundsvideobot
- Путь: `Roundsvideobot/Resources/temporaryvideoFiles`
- Volume: `./Roundsvideobot/Resources/temporaryvideoFiles:/app/Roundsvideobot/Resources/temporaryvideoFiles`
- Файлы сохраняются на Mac и доступны в контейнере

### Neurfotobot
- Путь: `Neurfotobot/tmp` (через `NEURFOTOBOT_TEMP_DIR`)
- Volume: `./Neurfotobot:/app/Neurfotobot`
- Файлы сохраняются на Mac

### PereskazNowBot
- Путь: `/tmp` (системная временная директория контейнера)
- Файлы удаляются автоматически после обработки
- Не требует volume (временные файлы)

## 💾 Работа с базами данных

### SQLite базы

Все SQLite базы монтируются через volumes:

```yaml
volumes:
  - ./config:/app/config  # monetization.sqlite
  - ./Neurfotobot:/app/Neurfotobot  # db.sqlite
  - ./contentfabrikabot:/app/contentfabrikabot  # db.sqlite
```

**Важно:**
- Базы создаются на Mac (в папках проекта)
- Доступны и в контейнере, и на Mac
- Формат одинаковый (Linux формат, так как создаются в контейнере)

## 🔀 Работа с ветками

### Ветка dev (разработка)

```bash
# Переключись на dev
git checkout dev

# Разрабатывай в Docker
docker compose -f docker-compose.dev.yml up

# Коммить изменения
git add .
git commit -m "feat: ..."
git push origin dev
```

### Ветка prod (продакшен)

```bash
# Переключись на prod
git checkout prod

# Смерджи изменения из dev
git merge dev

# Задеплой на сервер
git push origin prod

# На сервере
git pull origin prod
docker compose -f docker-compose.prod.yml up -d --build
```

## 🚀 Деплой на сервер

### Процесс

1. **Разработай в dev ветке** (локально в Docker)
2. **Протестируй локально**
3. **Смерджи в prod:**
   ```bash
   git checkout prod
   git merge dev
   git push origin prod
   ```
4. **На сервере:**
   ```bash
   git pull origin prod
   docker compose -f docker-compose.prod.yml up -d --build
   ```

### CI/CD (будущее)

Когда будешь готов, можно настроить:
- GitHub Actions для автоматического деплоя
- Автоматический билд при пуше в prod
- Автоматические тесты перед деплоем

## ❓ FAQ

### Почему код не обновляется в контейнере?

Убедись, что volume правильно смонтирован:
```yaml
volumes:
  - .:/app  # Монтирует всю папку проекта
```

И перезапусти контейнер:
```bash
docker compose -f docker-compose.dev.yml restart neurfotobot
```

### Как отладить проблему?

1. **Проверь логи:**
   ```bash
   docker compose -f docker-compose.dev.yml logs neurfotobot
   ```

2. **Зайди в контейнер:**
   ```bash
   docker compose -f docker-compose.dev.yml exec neurfotobot bash
   ```

3. **Проверь, что код смонтирован:**
   ```bash
   ls -la /app/Neurfotobot/Sources
   ```

### Можно ли использовать IDE для отладки?

Да! IDE работает с кодом на Mac, а Docker запускает код в Linux. Это нормально.

### Нужно ли пересобирать образ при изменении кода?

Нет! Код монтируется через volume, поэтому изменения видны сразу. Пересборка нужна только если изменился `Package.swift` или `Dockerfile.dev`.

## 📚 Дополнительные ресурсы

- [Docker Compose документация](https://docs.docker.com/compose/)
- [Vapor документация](https://docs.vapor.codes/)
- [Swift Package Manager](https://swift.org/package-manager/)

