Команды для запуска и отладки выполняем в отдельных вкладках терминала (Cmd + T). Перед началом убедись, что окружение настроено по инструкции из [`docs/SETUP_GUIDE.md`](SETUP_GUIDE.md)

> Разработчик использовал команду `cd /Users/a1111/Desktop/projects/Telegrambot` для локального запуска — подставь свой путь к проекту




1. Создай первую вкладку (Cmd + T) и запусти обратное проксирование NGINX. Это делаем один раз; `brew services` ставит его в автозапуск, и после перезагрузки nginx поднимается сам:

- Первый запуск (если ранее не поднимали через Homebrew):
  ```bash
  brew services start nginx
  ```

- Если ты уже запускал NGINX ранее, можешь проверить состояние сервиса:
  - Проверить статус:
    ```bash
    brew services list | grep nginx
    ```
    Пример ожидаемого вывода:
    ```
    nginx       started         a1111 ~/Library/LaunchAgents/homebrew.mxcl.nginx.plist
    ```
  - Или перезапустить при необходимости:
    ```bash
    brew services restart nginx
    ```

- Проверь, что NGINX слушает порт 8080:
  ```bash
  curl -s http://127.0.0.1:8080/ | head -n 3
  ```
  Если видишь HTML — NGINX работает. После этого команду можно не повторять до следующей настройки

- Останови, если требуется:
  ```bash
  brew services stop nginx
  ```




2. Проверь VPN: включи его и убедись, что соединение работает:
(Если видишь российский IP — то VPN НЕ работает, включи VPN и проверь снова!)

```bash
curl -s https://api.ipify.org
```




3. Создай вторую вкладку (Cmd + T) и запусти ngrok:

(Скопируй URL из логов — строка "Forwarding https://xxxxx-xxxxx-xxxxx.ngrok-free.app -> http://localhost:8080")

⚠️ Важно: ngrok для пользователей из России запускается только в терминале с включённым VPN. URL будет стабильным неделями, но если ты перезапустиim ngrock то выдаваемый тебе для Тестов URL изменится

⚠️ Если видишь ошибку ERR_NGROK_9040 — VPN НЕ работает, включи VPN и запусти ngrok снова!
(Эта вкладка должна оставаться открытой — ngrok работает постоянно)

```bash
ngrok http 8080 --log=stdout
```




4. Обнови BASE_URL: вставь URL в секретный файл config/.env на строку BASE_URL=https://xxxxx-xxxxx-xxxxx.ngrok-free.app (ориентируйся на шаблон `config/env.example` для структуры файла)
(Можно закрыть редактор после сохранения)



5. Создай третью вкладку (Cmd + T), загрузи переменные окружения и настрой webhook'и:

Проверка: если видишь все токены — всё ок
Эту вкладку можно закрыть после выполнения скрипта — webhook'и настроены

```bash
cd /Users/a1111/Desktop/projects/Telegrambot
set -a; source config/.env; set +a
env | grep -E 'NOWMTTBOT_TOKEN|NOWCONTROLLERBOT_TOKEN|VIDEO_BOT_TOKEN|GSFORTEXTBOT_TOKEN|NEURFOTOBOT_TOKEN|BANANANOWBOT_TOKEN|CONTENTFABRIKABOT_TOKEN'
./config/set-webhooks.sh
```




6. Запусти сервисы, которые тебе нужны (каждый запуск выполняй в новой вкладке терминала через Cmd + T). Вкладки держи открытыми, пока сервисы работают. Напоминаю: пример команды разработчика — `cd /Users/a1111/Desktop/projects/Telegrambot`, тебе нужно подставить свой путь!

> ⚠️ **При первом запуске после клонирования репозитория:** 
> Рекомендуется сначала запустить `NowControllerBot` для автоматической инициализации базы данных монетизации (`config/monetization.sqlite`) и создания записей для всех ботов из `NOWCONTROLLERBOT_BROADCAST_BOTS`. После этого можно запускать остальные сервисы в любом порядке. База данных создастся автоматически при запуске любого сервиса, но инициализация записей для ботов происходит только в `NowControllerBot`.

- VideoServiceRunner — основной обработчик Roundsvideobot
  ```bash
  cd /Users/a1111/Desktop/projects/Telegrambot
  set -a; source config/.env; set +a
  LOG_LEVEL=debug swift run VideoServiceRunner
  ```

- NowmttBot — скачивание TikTok без водяного знака
  ```bash
  cd /Users/a1111/Desktop/projects/Telegrambot
  set -a; source config/.env; set +a
  swift run NowmttBot
  ```

- GSForTextBot — голос в текст (SaluteSpeech)
  ```bash
  cd /Users/a1111/Desktop/projects/Telegrambot
  set -a; source config/.env; set +a
  swift run GSForTextBot serve
  ```

- ContentFabrikaBot — генерация постов для Telegram каналов в стиле автора
  ```bash
  cd /Users/a1111/Desktop/projects/Telegrambot
  set -a; source config/.env; set +a
  swift run ContentFabrikaBot
  ```

- Neurfotobot — бот для нейрофотографий (AI обработка изображений)
  ```bash
  cd /Users/a1111/Desktop/projects/Telegrambot
  set -a; source config/.env; set +a
  swift run Neurfotobot
  ```

- BananaNowBot — бот для использования Nano Banana (в разработке)
  ```bash
  cd /Users/a1111/Desktop/projects/Telegrambot
  set -a; source config/.env; set +a
  swift run BananaNowBot
  ```

- SoranowBot — бот для генерации видео из текстового описания с помощью Sora2 (в разработке)
  ```bash
  cd /Users/a1111/Desktop/projects/Telegrambot
  set -a; source config/.env; set +a
  swift run SoranowBot
  ```

- VeoNowBot - бот для генерации видео из текстового описания через Veo 3 (в разработке)
  ```bash
  cd /Users/a1111/Desktop/projects/Telegrambot
  set -a; source config/.env; set +a
  swift run VeoNowBot
  ```

- NowControllerBot — управление отправкой сообщений в боты NowBots и включение-выключение проверки на подписку каналов-спонсоров (в разработке)
  ```bash
  cd /Users/a1111/Desktop/projects/Telegrambot
  set -a; source config/.env; set +a
  swift run NowControllerBot
  ```

> Подробный план настройки GSForTextBot с ключами и сертификатами см. в [gsfortextbot/docs/SETUP_GSFORTEXTBOT.md](../gsfortextbot/docs/SETUP_GSFORTEXTBOT.md).
### Дополнение: быстрая настройка GSForTextBot

Если поднимаешь gsfortextbot впервые, выполни один раз:

```bash
mkdir -p config/certs
openssl s_client -showcerts \
  -servername ngw.devices.sberbank.ru \
  -connect ngw.devices.sberbank.ru:9443 </dev/null 2>/dev/null \
  | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' \
  > config/certs/salutespeech-chain.pem
```

Убедись, что в `config/.env` заполнены `GSFORTEXTBOT_TOKEN`, `SALUTESPEECH_AUTH_KEY`, `SALUTESPEECH_SCOPE`, `BASE_URL`.  
Webhook для бота: `https://<BASE_URL>/gs/text/webhook`




7. Проверочные команды — см. [docs/VERIFY.md](./VERIFY.md). Запускай их в отдельной вкладке (Cmd + T) и закрывай после завершения тестов




8. Зайди в @botfather, выбери активные боты (например, @roundsvideobot), открой "Bot settings" → "Menu button", нажми "Configure menu button" и вставь актуальный URL из ngrok




Вкладки, которые можно закрыть сразу после выполнения команды:
- Первая вкладка (шаг 1): nginx запущен как сервис — после запуска не требуется удерживать вкладку (`brew services` управляет в фоне)
- Третья вкладка (шаг 5): настройка вебхуков — закрывай после выполнения скрипта

Вкладки, которые держим открытыми постоянно для локальной отладки:
- Вторая вкладка (шаг 3): ngrok с внешним VPN — держи открытой постоянно и не закрывай, пока работаешь

Вкладки с сервисами (оставляй открытыми, если запускаешь соответствующий бот):
- Четвёртая вкладка (шаг 6): VideoServiceRunner (Roundsvideobot) — основной сервис формирования видеокружков
- Пятая вкладка (шаг 6): NowmttBot — загрузка TikTok без водяного знака
- Шестая вкладка (шаг 6): GSForTextBot — распознавание голосовых через SaluteSpeech
- Седьмая вкладка (шаг 6): ContentFabrikaBot — генерация постов для Telegram каналов в стиле автора
- Восьмая вкладка (шаг 6): Neurfotobot — нейрофотографии (AI обработка изображений)
- Девятая вкладка (шаг 6): BananaNowBot — прототип генерации медиа Nano Banana
- Десятая вкладка (шаг 6): SoranowBot — генерация видео с помощью Sora2 (в разработке)
- Одиннадцатая вкладка (шаг 6): VeoNowBot — генерация видео через Veo 3 (в разработке)
- Двенадцатая вкладка (шаг 6): NowControllerBot — управление отправкой сообщений в боты NowBots (в разработке)

Обычно активно несколько вкладок: ngrok (обязательно), сервисы, которые ты запускаешь самостоятельно
```
