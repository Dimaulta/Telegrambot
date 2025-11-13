## Инструкция по первичной установке компонентов для развёртывания сервиса
Автор разворачивает эти сервисы на Macbook M1 Pro 16GB




1. Установить Homebrew (менеджер пакетов для Mac). Если Homebrew уже установлен, пропусти этот шаг:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```




2. Установить FFmpeg:

```bash
brew install ffmpeg
```




3. Установить ngrok:

```bash
brew install ngrok
```




4. Установить nginx:

```bash
brew install nginx
```




5. Проверить, что Swift установлен:

```bash
swift --version
```

Если видишь версию Swift — всё ок. Если Swift не установлен, установи Xcode Command Line Tools командой `xcode-select --install`

> **Примечание о SQLite**: SQLite встроен в macOS и не требует отдельной установки. Проект использует FluentSQLiteDriver (Swift пакет), который автоматически подключается при установке зависимостей через `swift package resolve`




6. Клонировать репозиторий и перейти в папку проекта:

```bash
git clone REPO_URL
cd Telegrambot
```

Замени `REPO_URL` на реальный URL твоего репозитория. Дальше все команды выполняй из папки проекта




7. Создать файл конфигурации из примера:

```bash
cp config/env.example config/.env
```




8. Открыть config/.env в редакторе и заполнить токены ботов:

8.1. Получить токены в @BotFather в Telegram:
- Открыть @BotFather в Telegram
- Создать ботов командой /newbot
- Скопировать токены для каждого бота

8.2. Заполни `config/.env` своими значениями. Ориентируйся на структуру [`config/env.example`](../config/env.example), например:
```env
VIDEO_BOT_TOKEN=PASTE_VIDEO_BOT_TOKEN_HERE
```
Пополняй остальные поля аналогично, используя плейсхолдеры из примера

> Подробный чек-лист для SaluteSpeech (ключи, сертификаты, тесты API) см. в [gsfortextbot/docs/SETUP_PLAN.md](../gsfortextbot/docs/SETUP_PLAN.md).



9. Настроить nginx для проксирования запросов:

9.1. Найти путь к конфигурации nginx:

```bash
nginx -t
```

В выводе будет указан путь к конфигурации, например `/opt/homebrew/etc/nginx/nginx.conf` или `/usr/local/etc/nginx/nginx.conf`

9.2. Открыть конфигурацию nginx в редакторе:

```bash
open -a TextEdit /opt/homebrew/etc/nginx/nginx.conf
```

Можешь использовать любой текстовый редактор. Замени путь на тот, что получил в шаге 9.1

9.3. Найти блок server внутри блока http и заменить на:

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

    location /soranow/webhook {
        proxy_pass http://127.0.0.1:8086;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /veonow/webhook {
        proxy_pass http://127.0.0.1:8087;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /banananow/webhook {
        proxy_pass http://127.0.0.1:8088;
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

    location /nowmtt/webhook {
        proxy_pass http://127.0.0.1:8085;
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

    location /contentfabrika/webhook {
        proxy_pass http://127.0.0.1:8089/contentfabrika/webhook;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

9.4. Сохранить файл и закрыть редактор

9.5. Проверить конфигурацию nginx:

```bash
nginx -t
```

Если видишь `syntax is ok` и `test is successful`, значит всё ок



10. Выполнить тестовый запуск GSForTextBot (использует переменные из `config/.env`). Подробный сценарий запуска см. в [QUICK_START.md](./QUICK_START.md):

```bash
cd /Users/a1111/Desktop/projects/Telegrambot
set -a; source config/.env; set +a
swift run GSForTextBot serve
```

После проверки нажми Ctrl + C, чтобы остановить сервис. Для постоянной работы используй инструкции из QUICK_START.md



11. Установка завершена. Переходи к [QUICK_START.md](./QUICK_START.md) для запуска сервисов.
