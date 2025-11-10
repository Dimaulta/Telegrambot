# GSForTextBot — план установки и запуска

Документ описывает полный путь от получения токенов до запуска бота, который переводит голосовые сообщения в текст через SaluteSpeech.

## 1. Что потребуется

### Аккаунты и сервисы
- **Telegram Bot** — создаём через `@BotFather`, записываем токен (`GSFORTEXTBOT_TOKEN`).
- **SaluteSpeech (Сбер)** — регистрируемся в [Studio](https://developers.sber.ru/studio), создаём проект *SaluteSpeech API*.
- **Ngrok** (или другой туннель) — чтобы пробросить локальный сервер наружу, если разворачиваем на локальной машине.

### ПО
- macOS 12+ (проект собирается через Swift 6).
- Swift toolchain (см. `README.md` в корне).
- `ngrok` 3.x (если используем туннель).

## 2. Получение ключей SaluteSpeech

1. Открываем проект в Studio → **Настройки API**.
2. Нажимаем «Получить ключ», сохраняем `Authorization key` — кладём в `.env` как `SALUTESPEECH_AUTH_KEY`.
3. Сохраняем `Client ID` (не нужен напрямую, он уже зашит в `Authorization key`).
4. `Scope` для физ. лица — `SALUTE_SPEECH_PERS`. Для юрлица будет другой (см. документацию).

### Проверяем выдачу токена
```bash
source config/.env   # уже должен содержать SALUTESPEECH_AUTH_KEY и SALUTESPEECH_SCOPE
curl -X POST 'https://ngw.devices.sberbank.ru:9443/api/v2/oauth' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'Accept: application/json' \
  -H "RqUID: $(uuidgen)" \
  -H "Authorization: Basic $SALUTESPEECH_AUTH_KEY" \
  --data-urlencode "scope=$SALUTESPEECH_SCOPE"
```
В ответ приходит `access_token`. В коде бот обновляет его каждые 30 минут автоматически.

## 3. Корневой сертификат SaluteSpeech

Чтобы клиент доверял TLS, снимаем цепочку с сервера и кладём в `config/certs`:

```bash
mkdir -p config/certs
openssl s_client -showcerts \
  -servername ngw.devices.sberbank.ru \
  -connect ngw.devices.sberbank.ru:9443 </dev/null 2>/dev/null \
  | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' \
  > config/certs/salutespeech-chain.pem
```

Теперь при запуске бота сертификаты подхватятся автоматически.  
Если несколько окружений — можно указать путь через `SALUTESPEECH_CA_PATH=/abs/path/to/pem`.

## 4. Настройка `.env`

Создаём/обновляем `config/.env` (файл уже игнорируется в git):

```env
GSFORTEXTBOT_TOKEN=123456:ABCDEF...
SALUTESPEECH_AUTH_KEY="Base64-ключ из Studio"
SALUTESPEECH_SCOPE=SALUTE_SPEECH_PERS
SALUTESPEECH_TOKEN_URL=https://ngw.devices.sberbank.ru:9443/api/v2/oauth
SALUTESPEECH_RECOGNIZE_URL=https://smartspeech.sber.ru/rest/v1/speech:recognize
BASE_URL=https://<ngrok-домен или ваш домен>
```

## 5. Проксирование / nginx

В `telegrambots.conf` уже есть секция:

```
location /gs/text/webhook {
    proxy_pass http://127.0.0.1:8083/webhook;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Важно, чтобы внешний URL шёл на `/gs/text/webhook`.  
Если используется ngrok + nginx, ngrok должен слушать порт 8080 (где крутится nginx).

## 6. Установка webhook Telegram

После того как поднят туннель и известен публичный URL:

```bash
source config/.env
curl -X POST "https://api.telegram.org/bot${GSFORTEXTBOT_TOKEN}/setWebhook" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"${BASE_URL}/gs/text/webhook\"}"

curl "https://api.telegram.org/bot${GSFORTEXTBOT_TOKEN}/getWebhookInfo"
```

`url` в ответе должен совпасть с `BASE_URL/gs/text/webhook`, `pending_update_count` — 0 (или небольшое число, если стоят в очереди).

## 7. Локальный запуск

```bash
cd /Users/<user>/Desktop/projects/Telegrambot
export $(grep -v '^#' config/.env | xargs)
swift run GSForTextBot serve
```

Логи покажут:
- выдачу токена (`SaluteSpeechAuthService: obtained new token...`);
- входящие сообщения (`POST /webhook ...`);
- текст ответа или диагностические сообщения.

## 8. Проверка работы

1. В Телеграме отправляем `/start` — бот отвечает инструкцией.
2. Пересылаем голосовое или аудиофайл — в ответ получаем текст.
3. Если бот молчит:
   - проверить `getWebhookInfo`;
   - убедиться, что ngrok активен;
   - посмотреть логи (в них будет причина).

## 9. Деплой на VPS

На внешнем сервере последовательность та же:
1. Установить Swift toolchain / Docker (по желанию).
2. Скопировать проект + `config/.env` (через секреты/CI).
3. Положить `salutespeech-chain.pem` в `config/certs/` или доверить сертификат через системное CA.
4. Запустить сервис (`swift run GSForTextBot serve` / `systemd` / контейнер).
5. Прописать `BASE_URL` на внешний домен и перевязать webhook.

## 10. Полезные команды

- Снять логи вебхука:
  ```bash
  curl "https://api.telegram.org/bot${GSFORTEXTBOT_TOKEN}/getWebhookInfo"
  ```
- Удалить webhook (для отладки):
  ```bash
  curl "https://api.telegram.org/bot${GSFORTEXTBOT_TOKEN}/deleteWebhook"
  ```
- Проверить trust-chain вручную:
  ```bash
  openssl s_client -servername smartspeech.sber.ru -connect smartspeech.sber.ru:443
  ```

## 11. Расширения / TODO

- Добавить хранение истории расшифровок (БД).
- Сделать кастомные ответы/форматирование текста.
- Паковать в Docker-контейнер с заранее добавленным сертификатом.

Бот уже готов к работе: он автоматически обновляет токены, доверяет SaluteSpeech через локальный PEM и расшифровывает голосовые сообщения. Остаётся только настроить окружение по этому плану 💚

