# 🚀 Быстрый старт: Разработка в Docker

## 💡 Что это даёт?

**Проблема была:**
- Разработка на Mac → деплой на Linux → проблемы с путями, БД, функциями

**Решение:**
- Код редактируешь на Mac в IDE (как обычно)
- Запуск происходит в Docker контейнере (Linux окружение)
- Окружение одинаковое → проблем нет при деплое

## ⚡ Быстрый старт (5 минут)

### 1. Убедись, что Docker запущен

```bash
docker --version
```

### 2. Создай временные папки (если их нет)

```bash
mkdir -p Roundsvideobot/Resources/temporaryvideoFiles
mkdir -p Neurfotobot/tmp
```

### 3. Запусти один сервис для теста

```bash
docker compose -f docker-compose.dev.yml up nowcontrollerbot
```

### 4. Проверь логи

Должно быть:
```
[ INFO ] Server started on http://0.0.0.0:8084
```

### 5. Останови (Ctrl+C) и запусти все сервисы

```bash
docker compose -f docker-compose.dev.yml up
```

## 📝 Обычный workflow

### Разработка:

1. **Запусти сервисы:**
   ```bash
   docker compose -f docker-compose.dev.yml up neurfotobot
   ```

2. **Редактируй код в IDE** (как обычно)

3. **После изменений - перезапусти:**
   ```bash
   docker compose -f docker-compose.dev.yml restart neurfotobot
   ```

4. **Тестируй через ngrok** (на Mac, не в контейнере):
   ```bash
   ngrok http 8080
   ```

### Деплой:

1. **Коммить изменения:**
   ```bash
   git add .
   git commit -m "feat: ..."
   git push origin dev
   ```

2. **Смерджить в prod:**
   ```bash
   git checkout prod
   git merge dev
   git push origin prod
   ```

3. **На сервере:**
   ```bash
   git pull origin prod
   docker compose -f docker-compose.prod.yml up -d --build
   ```

## 🔍 Полезные команды

```bash
# Запустить все сервисы
docker compose -f docker-compose.dev.yml up

# Запустить в фоне
docker compose -f docker-compose.dev.yml up -d

# Остановить
docker compose -f docker-compose.dev.yml down

# Логи
docker compose -f docker-compose.dev.yml logs -f neurfotobot

# Перезапустить один сервис
docker compose -f docker-compose.dev.yml restart neurfotobot

# Зайти в контейнер
docker compose -f docker-compose.dev.yml exec neurfotobot bash
```

## ❓ FAQ

**Q: Нужно ли пересобирать образ при изменении кода?**  
A: Нет! Код монтируется через volume, изменения видны сразу. Перезапусти контейнер.

**Q: Можно ли использовать IDE для отладки?**  
A: Да! IDE работает с кодом на Mac, Docker запускает в Linux - это нормально.

**Q: Где хранятся БД и временные файлы?**  
A: На Mac (в папках проекта), доступны и в контейнере через volumes.

## 📚 Подробная документация

- [DEVELOPMENT_IN_DOCKER.md](DEVELOPMENT_IN_DOCKER.md) - полная документация
- [DEVELOPMENT_MIGRATION_PLAN.md](DEVELOPMENT_MIGRATION_PLAN.md) - план миграции

