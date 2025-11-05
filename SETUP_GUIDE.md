Автор развертывает эти сервисы на Macbook M1 Pro 16GB.



1. Установить Homebrew (менеджер пакетов для Mac):

(Если Homebrew уже установлен, пропусти этот шаг)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```



2. Установить Docker Desktop:

2.1. Скачать Docker Desktop для Mac:
- Открыть https://www.docker.com/products/docker-desktop/
- Скачать Docker Desktop для Apple Silicon (M1/M2/M3)
- Установить приложение, перетащив в папку Applications

2.2. Запустить Docker Desktop и дождаться полной загрузки:
(Иконка в строке меню перестанет анимироваться)

2.3. Проверить, что Docker работает:

```bash
docker ps
```

(Если видишь список контейнеров или пустой вывод — всё ок)



3. Установить FFmpeg:

```bash
brew install ffmpeg
```



4. Установить ngrok:

```bash
brew install ngrok
```



5. Установить nginx:

```bash
brew install nginx
```



6. Проверить, что Swift установлен:

```bash
swift --version
```

(Если видишь версию Swift — всё ок)
(Если Swift не установлен — установить Xcode Command Line Tools: xcode-select --install)



7. Клонировать репозиторий и перейти в папку проекта:

```bash
git clone <URL-РЕПОЗИТОРИЯ>
cd Telegrambot
```

(Замени <URL-РЕПОЗИТОРИЯ> на реальный URL твоего репозитория)
(В дальнейшем все команды выполняй из папки проекта)



8. Создать файл конфигурации из примера:

```bash
cp config/env.example config/.env
```



9. Открыть config/.env в редакторе и заполнить токены ботов:

9.1. Получить токены в @BotFather в Telegram:
- Открыть @BotFather в Telegram
- Создать ботов командой /newbot
- Скопировать токены для каждого бота

9.2. Вставить токены в config/.env:
- VIDEO_BOT_TOKEN=твой-токен-для-video-bot
- SORANOWBOT_TOKEN=твой-токен-для-sora-bot
- GSFORTEXTBOT_TOKEN=твой-токен-для-gs-bot
- NEURFOTOBOT_TOKEN=твой-токен-для-neurfoto-bot

(Пока что BASE_URL можно оставить как есть, обновим позже)



10. Настроить nginx для проксирования запросов:

10.1. Найти путь к конфигурации nginx:

```bash
nginx -t
```

(В выводе будет указан путь к конфигурации, например: /opt/homebrew/etc/nginx/nginx.conf или /usr/local/etc/nginx/nginx.conf)

10.2. Открыть конфигурацию nginx в редакторе:

```bash
open -a TextEdit /opt/homebrew/etc/nginx/nginx.conf
```

(Или использовать любой текстовый редактор, замени путь на тот что получил в шаге 10.1)

10.3. Найти блок server внутри блока http и заменить на:

```
server {
    listen 8080;
    server_name localhost;

    location /sora/webhook {
        proxy_pass http://127.0.0.1:8084;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /rounds/webhook {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /gs/text/webhook {
        proxy_pass http://127.0.0.1:8083;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /neurfoto/webhook {
        proxy_pass http://127.0.0.1:8082;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

10.4. Сохранить файл и закрыть редактор

10.5. Проверить конфигурацию nginx:

```bash
nginx -t
```

(Если видишь "syntax is ok" и "test is successful" — всё ок)



11. Собрать Docker контейнер для Playwright сервиса:

(Убедись что ты находишься в папке проекта)

```bash
docker compose build playwright-service
```

(Это займет 10-15 минут при первом запуске)



12. Установка завершена. Переходи к QUICK_START.md для запуска сервисов.
