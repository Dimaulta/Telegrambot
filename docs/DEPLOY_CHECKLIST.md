# ✅ Чеклист деплоя на Production сервер

## 📊 Текущее состояние

### ✅ Что уже готово:
- [x] DNS настроен: `nowbots.ru` → `85.208.110.226`
- [x] Docker Compose файлы настроены
- [x] Traefik конфигурация создана
- [x] Автоматический HTTPS через Let's Encrypt настроен
- [x] Все боты настроены для работы через Traefik

### ⚠️ Что нужно сделать:

## 1. Установка Docker и Docker Compose

```bash
# Обновляем систему
sudo apt update && sudo apt upgrade -y

# Устанавливаем Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Добавляем пользователя в группу docker
sudo usermod -aG docker $USER

# Выходим и заходим снова
exit
# (затем заново подключаемся по SSH)

# Устанавливаем Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Проверяем установку
docker --version
docker compose version
```

## 2. Настройка Firewall

```bash
# Открываем порты 80 и 443
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 22/tcp  # SSH (если еще не открыт)
sudo ufw status
```

## 3. Передача .env файла на сервер

**С MacBook через SCP:**
```bash
scp config/.env root@85.208.110.226:/root/Telegrambot/config/.env
```

**На сервере:**
```bash
cd /root/Telegrambot
chmod 600 config/.env
```

## 4. Обновление BASE_URL в .env

Открой `config/.env` и убедись что:
```env
BASE_URL=https://nowbots.ru
```

**Важно:** Используй домен (не IP), иначе Let's Encrypt не выдаст сертификат.

## 5. Проверка email в Traefik

Открой `config/traefik.yml` и проверь email:
```yaml
email: lightpaintru@gmail.com  # ← Убедись что это правильный email
```

## 6. Создание необходимых директорий

```bash
cd /root/Telegrambot
mkdir -p Roundsvideobot/Resources/temporaryvideoFiles
mkdir -p Neurfotobot/tmp
mkdir -p config/certs
mkdir -p config/traefik/letsencrypt
```

## 7. Запуск контейнеров

```bash
cd /root/Telegrambot

# Собираем образы (может занять 10-15 минут)
docker compose -f docker-compose.prod.yml build

# Запускаем сервисы
docker compose -f docker-compose.prod.yml up -d

# Проверяем статус
docker compose -f docker-compose.prod.yml ps
```

## 8. Проверка работы

### Проверка SSL сертификата (подожди 1-2 минуты после запуска)

```bash
# Проверь что сертификат получен
curl -I https://nowbots.ru/neurfoto/webhook

# Должен вернуть HTTP/2 200 или 404 (но с HTTPS!)
```

### Проверка логов Traefik

```bash
docker compose -f docker-compose.prod.yml logs -f traefik
```

Ищи строки типа:
```
time="..." level=info msg="Certificate obtained from ACME"
```

## 9. Настройка Webhooks

После успешного запуска настрой webhooks для всех ботов:

```bash
cd /root/Telegrambot
set -a; source config/.env; set +a
./config/set-webhooks.sh
```

Или вручную через Telegram API:
- `https://nowbots.ru/neurfoto/webhook` для Neurfotobot
- `https://nowbots.ru/nowmtt/webhook` для NowmttBot
- `https://nowbots.ru/rounds/webhook` для Roundsvideobot
- И т.д. (см. `config/services.json`)

## 🔍 Полезные команды

### Просмотр логов
```bash
# Все сервисы
docker compose -f docker-compose.prod.yml logs -f

# Конкретный сервис
docker compose -f docker-compose.prod.yml logs -f neurfotobot
```

### Перезапуск сервиса
```bash
docker compose -f docker-compose.prod.yml restart neurfotobot
```

### Остановка всех сервисов
```bash
docker compose -f docker-compose.prod.yml down
```

### Обновление после изменений в коде
```bash
git pull
docker compose -f docker-compose.prod.yml down
docker compose -f docker-compose.prod.yml build --no-cache
docker compose -f docker-compose.prod.yml up -d
```

## 🐛 Решение проблем

### Docker не установлен
См. шаг 1 выше.

### Порт 80/443 занят
```bash
# Проверь что занимает порт
sudo netstat -tulpn | grep :80
sudo netstat -tulpn | grep :443

# Останови старый nginx если есть
sudo systemctl stop nginx
sudo systemctl disable nginx
```

### SSL сертификат не получается
1. Проверь DNS: `dig nowbots.ru +short`
2. Проверь что порт 80 открыт: `sudo ufw status`
3. Проверь логи Traefik: `docker compose -f docker-compose.prod.yml logs traefik`

### Бот не отвечает
1. Проверь что контейнер запущен: `docker compose -f docker-compose.prod.yml ps`
2. Проверь логи бота: `docker compose -f docker-compose.prod.yml logs -f neurfotobot`
3. Проверь что `.env` файл заполнен правильно

## 📚 Дополнительная документация

- **Полная инструкция**: `docs/DEPLOY.md`
- **Настройка Traefik**: `docs/TRAEFIK_SETUP.md`
- **Безопасная передача .env**: `docs/ENV_SECURITY.md`
- **Быстрый старт**: `docs/DEPLOY_QUICK.md`

