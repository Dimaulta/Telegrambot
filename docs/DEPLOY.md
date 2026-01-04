# 🚀 Деплой на Production сервер

## 📋 Быстрый чеклист

### ✅ Подготовка (на MacBook)

- [ ] Клонирован репозиторий или обновлен через `git pull`
- [ ] Файл `config/.env` заполнен всеми токенами
- [ ] `BASE_URL` в `.env` указывает на домен сервера (например: `https://nowbots.ru`)

### ✅ На сервере

- [ ] Docker и Docker Compose установлены
- [ ] Порт 80 и 443 открыты в firewall
- [ ] DNS настроен: домен указывает на IP сервера
- [ ] Файл `config/.env` передан на сервер
- [ ] Email в Traefik конфигурации обновлён
- [ ] Необходимые директории созданы
- [ ] Контейнеры собраны и запущены
- [ ] Webhooks настроены для всех ботов

---

## 🔒 Безопасная передача .env файла

**⚠️ ВАЖНО: Никогда не коммить `.env` файл в Git!**

### Способ 1: SCP (рекомендуется)

```bash
# С MacBook передай .env файл на сервер
scp config/.env root@nowbots.ru:/root/Telegrambot/config/.env

# На сервере проверь права доступа
ssh root@nowbots.ru
chmod 600 /root/Telegrambot/config/.env
```

### Способ 2: Через SSH и nano/vim

```bash
# Подключись к серверу
ssh root@nowbots.ru

# Создай файл на сервере
cd /root/Telegrambot
nano config/.env

# Вставь содержимое из своего .env файла с MacBook
# Сохрани файл (Ctrl+O, Enter, Ctrl+X)

# Установи правильные права
chmod 600 config/.env
```

### Способ 3: Через зашифрованный архив

```bash
# На MacBook создай зашифрованный архив
cd /path/to/Telegrambot
tar -czf - config/.env | openssl enc -aes-256-cbc -salt -out env.tar.gz.enc
# Введи пароль и запомни его!

# Передай архив на сервер
scp env.tar.gz.enc root@nowbots.ru:/tmp/

# На сервере расшифруй
ssh root@nowbots.ru
cd /root/Telegrambot
mkdir -p config
openssl enc -aes-256-cbc -d -in /tmp/env.tar.gz.enc | tar -xzf - -C .
chmod 600 config/.env
rm /tmp/env.tar.gz.enc
```

---

## 📋 Подготовка сервера

### Требования

- Linux сервер (Ubuntu/Debian рекомендуется)
- Docker и Docker Compose установлены
- Минимум 2GB RAM
- Минимум 10GB свободного места на диске
- Домен с настроенным DNS (для автоматического SSL через Let's Encrypt)
- Открытые порты 80 и 443 в firewall

### Установка Docker и Docker Compose

```bash
# Обновляем систему
sudo apt update && sudo apt upgrade -y

# Устанавливаем Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Добавляем текущего пользователя в группу docker
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

### Настройка Firewall

```bash
# Открываем порты 80 и 443
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 22/tcp  # SSH (если еще не открыт)
sudo ufw status
```

---

## 🚀 Процесс деплоя

### Шаг 1: Клонирование репозитория

```bash
# Если еще не клонировал
git clone https://github.com/Dimaulta/Telegrambot.git
cd Telegrambot
```

### Шаг 2: Передача .env файла

Используй один из способов выше для передачи `config/.env` на сервер.

### Шаг 3: Настройка BASE_URL и Traefik

1. **Открой `config/.env` и обнови `BASE_URL`:**

```env
BASE_URL=https://nowbots.ru
```

**Важно:** Используй свой реальный домен (не IP адрес) для работы с Let's Encrypt.

2. **Обнови email в Traefik конфигурации:**

Открой `config/traefik.yml` и замени email на свой:

```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@nowbots.ru  # ← Замени на свой email
```

3. **Проверь DNS настройки:**

```bash
dig nowbots.ru +short
# Должен вернуть IP твоего сервера
```

### Шаг 4: Создание необходимых директорий

```bash
mkdir -p Roundsvideobot/Resources/temporaryvideoFiles
mkdir -p Neurfotobot/tmp
mkdir -p config/certs
mkdir -p config/traefik/letsencrypt
```

### Шаг 5: Запуск контейнеров

```bash
cd /root/Telegrambot

# Собираем образы (может занять 10-15 минут)
docker compose -f docker-compose.prod.yml build

# Запускаем сервисы
docker compose -f docker-compose.prod.yml up -d

# Проверяем статус
docker compose -f docker-compose.prod.yml ps
```

### Шаг 6: Проверка работы

**Проверка SSL сертификата (подожди 1-2 минуты после запуска):**

```bash
# Проверь что сертификат получен
curl -I https://nowbots.ru/neurfoto/webhook

# Должен вернуть HTTP/2 200 или 404 (но с HTTPS!)
```

**Проверка логов Traefik:**

```bash
docker compose -f docker-compose.prod.yml logs -f traefik
```

Ищи строки типа:
```
time="..." level=info msg="Certificate obtained from ACME"
```

### Шаг 7: Настройка Webhooks

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
- `https://nowbots.ru/gs/text/webhook` для GSForTextBot
- `https://nowbots.ru/contentfabrika/webhook` для ContentFabrikaBot
- `https://nowbots.ru/pereskaznow/webhook` для PereskazNowBot
- `https://nowbots.ru/nowcontroller/webhook` для NowControllerBot

**Важно:** Все webhook'и должны использовать HTTPS (не HTTP) для работы с Telegram API.

---

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

---

## 🐛 Решение проблем

### Docker не установлен

См. раздел "Установка Docker и Docker Compose" выше.

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

### Проблемы с правами доступа

```bash
# Убедись, что у пользователя есть права на Docker
sudo usermod -aG docker $USER
# Выйди и зайди снова

# Проверь права на .env файл
chmod 600 config/.env
```

---

## 🔄 Обновление проекта

При обновлении кода:

```bash
# Обновляем код
git pull

# Пересобираем и перезапускаем
docker compose -f docker-compose.prod.yml down
docker compose -f docker-compose.prod.yml build --no-cache
docker compose -f docker-compose.prod.yml up -d
```

---

## 🛑 Остановка сервисов

```bash
# Остановить все сервисы
docker compose -f docker-compose.prod.yml down

# Остановить с удалением volumes (осторожно — удалит данные БД!)
docker compose -f docker-compose.prod.yml down -v
```

---

## 📝 Дополнительные настройки

### Автозапуск при перезагрузке сервера

Docker Compose с `restart: unless-stopped` автоматически перезапустит контейнеры при перезагрузке сервера.

### Мониторинг

Рекомендуется использовать мониторинг для отслеживания состояния сервисов:
- [Portainer](https://www.portainer.io/) — веб-интерфейс для Docker
- [Prometheus + Grafana](https://prometheus.io/) — для метрик
- Простые скрипты проверки health endpoints

### Бэкапы

Регулярно делай бэкапы:
- БД: `config/monetization.sqlite`, `contentfabrikabot/db.sqlite`
- Файлы: временные директории (если нужно сохранить данные)

```bash
# Пример бэкапа
tar -czf backup-$(date +%Y%m%d).tar.gz config/*.sqlite contentfabrikabot/db.sqlite
```

---

## 🔐 Безопасность

1. **HTTPS настроен автоматически** через Traefik и Let's Encrypt
2. **Не храни `.env` в Git**
3. **Регулярно обновляй токены ботов**
4. **Используй firewall** для ограничения доступа к портам (только 80, 443, 22)
5. **Регулярно обновляй Docker образы** для безопасности
6. **Измени пароль Traefik Dashboard** (см. `docs/TRAEFIK_SETUP.md`)

---

## 📚 Дополнительная документация

- **Настройка Traefik**: `docs/TRAEFIK_SETUP.md` — подробная инструкция по Traefik и SSL
- **Безопасная передача .env**: `docs/ENV_SECURITY.md` — способы передачи секретов
- **SSH настройка**: `docs/SSH_SETUP.md` — настройка SSH ключей и безопасного доступа

---

## 📞 Поддержка

При возникновении проблем:
1. Проверь логи сервисов
2. Убедись, что все зависимости установлены
3. Проверь документацию в папке `docs/`
