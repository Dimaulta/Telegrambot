# 🚀 Быстрый деплой - Чеклист

Краткая инструкция для быстрого деплоя проекта на сервер.

## Подготовка (на MacBook)

- [ ] Клонирован репозиторий или обновлен через `git pull`
- [ ] Файл `config/.env` заполнен всеми токенами
- [ ] `BASE_URL` в `.env` указывает на домен/IP сервера

## На сервере

### 1. Установка зависимостей

```bash
# Docker
curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh
sudo usermod -aG docker $USER
exit  # Выйди и зайди снова

# Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

### 2. Клонирование проекта

```bash
git clone https://github.com/Dimaulta/Telegrambot.git
cd Telegrambot
```

### 3. Передача .env файла

**Способ 1 (SCP):**
```bash
# С MacBook:
scp config/.env user@server:/path/to/Telegrambot/config/.env

# На сервере:
chmod 600 config/.env
```

**Способ 2 (вручную):**
```bash
# На сервере:
nano config/.env
# Вставь содержимое .env с MacBook, сохрани (Ctrl+O, Enter, Ctrl+X)
chmod 600 config/.env
```

### 4. Запуск деплоя

```bash
./config/deploy.sh
```

Или вручную:

```bash
docker compose -f docker-compose.prod.yml build
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml ps
```

### 5. Настройка webhooks

```bash
set -a; source config/.env; set +a
./config/set-webhooks.sh
```

### 6. Проверка

```bash
# Статус
docker compose -f docker-compose.prod.yml ps

# Логи
docker compose -f docker-compose.prod.yml logs -f
```

## ✅ Готово!

Если все сервисы запущены (`Up` статус), проект развернут успешно.

## 🔄 Обновление

```bash
git pull
docker compose -f docker-compose.prod.yml down
docker compose -f docker-compose.prod.yml build --no-cache
docker compose -f docker-compose.prod.yml up -d
```

## 📚 Подробная документация

- Полная инструкция: [DEPLOY.md](./DEPLOY.md)
- Безопасная передача .env: [ENV_SECURITY.md](./ENV_SECURITY.md)
