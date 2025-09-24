# Руководство по развертыванию

## Локальная разработка

### Требования
- macOS 12.0+
- Swift 5.9+
- FFmpeg (через Homebrew: `brew install ffmpeg`)

### Установка
```bash
# Клонирование репозитория
git clone <repository-url>
cd telegrambot01

# Создание конфигурации
cp config/env.example config/.env
# Отредактируйте config/.env с вашими токенами

# Запуск сервисов
swift run App &              # Core server (порт 8080)
swift run VideoServiceRunner # Video service (порт 8081)
```

### Настройка ngrok (для тестирования)
```bash
# Установка ngrok
brew install ngrok

# Запуск туннеля
ngrok http 8080

# Обновите BASE_URL в config/.env на ngrok URL
```

## Продакшен развертывание

### Серверные требования
- Ubuntu 20.04+ / CentOS 8+
- Swift 5.9+
- FFmpeg
- Nginx/Caddy
- SSL сертификат

### 1. Подготовка сервера
```bash
# Установка Swift
wget https://download.swift.org/swift-5.9-release/ubuntu2004/swift-5.9-RELEASE/swift-5.9-RELEASE-ubuntu20.04.tar.gz
tar xzf swift-5.9-RELEASE-ubuntu20.04.tar.gz
sudo mv swift-5.9-RELEASE-ubuntu20.04 /opt/swift
echo 'export PATH=/opt/swift/usr/bin:$PATH' >> ~/.bashrc

# Установка FFmpeg
sudo apt update
sudo apt install ffmpeg

# Установка Nginx
sudo apt install nginx
```

### 2. Развертывание приложения
```bash
# Клонирование и сборка
git clone <repository-url> /opt/telegrambot01
cd /opt/telegrambot01

# Создание конфигурации
sudo cp config/env.example config/.env
sudo nano config/.env  # Добавьте ваши токены

# Сборка релизной версии
swift build -c release

# Создание systemd сервисов
sudo nano /etc/systemd/system/telegrambot-core.service
sudo nano /etc/systemd/system/telegrambot-video.service
```

### 3. Systemd сервисы

**telegrambot-core.service:**
```ini
[Unit]
Description=Telegram Bot Core Server
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/telegrambot01
ExecStart=/opt/telegrambot01/.build/release/App
Restart=always
Environment=PORT=8080

[Install]
WantedBy=multi-user.target
```

**telegrambot-video.service:**
```ini
[Unit]
Description=Telegram Bot Video Service
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/telegrambot01
ExecStart=/opt/telegrambot01/.build/release/VideoServiceRunner
Restart=always
Environment=PORT=8081

[Install]
WantedBy=multi-user.target
```

### 4. Nginx конфигурация
```nginx
server {
    listen 443 ssl http2;
    server_name your-domain.com;
    
    ssl_certificate /path/to/certificate.crt;
    ssl_certificate_key /path/to/private.key;
    
    # Проксирование к core-server
    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # Прямое проксирование к video-service для miniapp
    location /api/ {
        proxy_pass http://localhost:8081;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### 5. Запуск сервисов
```bash
# Перезагрузка systemd
sudo systemctl daemon-reload

# Запуск сервисов
sudo systemctl enable telegrambot-core
sudo systemctl enable telegrambot-video
sudo systemctl start telegrambot-core
sudo systemctl start telegrambot-video

# Проверка статуса
sudo systemctl status telegrambot-core
sudo systemctl status telegrambot-video
```

### 6. Настройка webhook'ов
```bash
# Обновите BASE_URL в config/.env на ваш домен
# Затем настройте webhook'и для каждого бота:

curl -X POST "https://api.telegram.org/botVIDEO_BOT_TOKEN/setWebhook" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://your-domain.com/webhook"}'
```

## Docker развертывание

### Dockerfile
```dockerfile
FROM swift:5.9-focal

WORKDIR /app
COPY . .

RUN swift build -c release

EXPOSE 8080
CMD [".build/release/App"]
```

### docker-compose.yml
```yaml
version: '3.8'
services:
  core-server:
    build: .
    ports:
      - "8080:8080"
    environment:
      - VIDEO_BOT_TOKEN=${VIDEO_BOT_TOKEN}
    volumes:
      - ./config:/app/config
      
  video-service:
    build: .
    command: .build/release/VideoServiceRunner
    ports:
      - "8081:8081"
    environment:
      - VIDEO_BOT_TOKEN=${VIDEO_BOT_TOKEN}
    volumes:
      - ./config:/app/config
      - ./Resources:/app/Resources
```

## Мониторинг

### Логи
```bash
# Просмотр логов
sudo journalctl -u telegrambot-core -f
sudo journalctl -u telegrambot-video -f

# Логи Nginx
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log
```

### Health checks
```bash
# Проверка core-server
curl http://localhost:8080/hello

# Проверка video-service
curl http://localhost:8081/

# Проверка webhook
curl -X POST https://your-domain.com/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1}'
```

## Обновление

### Обновление кода
```bash
cd /opt/telegrambot01
git pull origin main
swift build -c release
sudo systemctl restart telegrambot-core
sudo systemctl restart telegrambot-video
```

### Обновление конфигурации
```bash
# Обновите config/.env
sudo nano config/.env

# Перезапустите сервисы
sudo systemctl restart telegrambot-core
sudo systemctl restart telegrambot-video
```

## Резервное копирование

### Важные файлы для бэкапа
- `config/.env` — токены и настройки
- `config/server.json` — конфигурация сервера
- `config/services.json` — конфигурация сервисов
- База данных SQLite (если используется)

### Автоматический бэкап
```bash
#!/bin/bash
# backup.sh
DATE=$(date +%Y%m%d_%H%M%S)
tar -czf "/backup/telegrambot_${DATE}.tar.gz" \
  /opt/telegrambot01/config/ \
  /opt/telegrambot01/db.sqlite
```
