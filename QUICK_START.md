```markdown



1. Открыть Docker Desktop приложение (запустить первым)


2. В терминале запустить NGINX как системный сервис и проверить работу:

(Если видишь "Service `nginx` already started" — это нормально, nginx уже работает)
(Если видишь HTML в выводе curl — всё ок, nginx работает)
(Терминал можно закрыть после проверки — nginx работает как системный сервис в фоне)

```bash
brew services start nginx
curl -s http://127.0.0.1:8080/ | head -n 3
```



3. Проверить, запущен ли playwright-service автоматически:

```bash
docker ps | grep playwright-service
```

3.1. Если контейнер УЖЕ запущен — перейти к шагу 4
3.2. Если контейнер НЕ запущен — создать вторую вкладку терминала Cmd + T и запустить:
(Эта вкладка может оставаться открытой или быть закрыта — контейнер работает в фоне)

```bash
cd /Users/a1111/Desktop/projects/Telegrambot
docker compose up playwright-service
```



4. Включить VPN и проверить, что VPN работает:
(Если видишь российский IP — VPN НЕ работает, включи VPN и проверь снова!)

```bash
curl -s https://api.ipify.org
```



5. Создать первую вкладку терминала Cmd + T, запустить ngrok:

(Скопировать URL из логов - строка "Forwarding https://xxxxx-xxxxx-xxxxx.ngrok-free.app -> http://localhost:8080")
⚠️ ВАЖНО: ngrok запускается ТОЛЬКО в терминале с VPN! URL будет стабильным неделями.
⚠️ Если видишь ошибку ERR_NGROK_9040 — VPN НЕ работает, включи VPN и запусти ngrok снова!
(Эта вкладка должна оставаться открытой — ngrok работает постоянно)

```bash
ngrok http 8080 --log=stdout
```



6. Вставить URL в файл config/.env на строку BASE_URL=https://xxxxx-xxxxx-xxxxx.ngrok-free.app
(Можно закрыть редактор после сохранения)



7. Создать вторую вкладку терминала Cmd + T, загрузить переменные окружения для проверки и настроить webhook'и:

(Проверка: если видишь все 4 токена — всё ок)
(Эту вкладку можно закрыть после выполнения скрипта — webhook'и настроены)

```bash
cd /Users/a1111/Desktop/projects/Telegrambot
set -a; source config/.env; set +a
env | grep -E 'SORANOWBOT_TOKEN|VIDEO_BOT_TOKEN|GSFORTEXTBOT_TOKEN|NEURFOTOBOT_TOKEN'
./config/set-webhooks-manual.sh
```



8. Создать третью вкладку терминала Cmd + T и запустить Roundsvideobot:
(Эта вкладка должна оставаться открытой — сервис работает постоянно)

```bash
cd /Users/a1111/Desktop/projects/Telegrambot && LOG_LEVEL=debug swift run VideoServiceRunner
```



9. Создать четвертую вкладку терминала Cmd + T и запустить Soranowbot:
(Эта вкладка должна оставаться открытой — сервис работает постоянно)

```bash
cd /Users/a1111/Desktop/projects/Telegrambot && LOG_LEVEL=debug swift run SoranowBot
```


9.1. Создать дополнительную вкладку терминала Cmd + T и запустить NowmttBot:
(Эта вкладка должна оставаться открытой — сервис работает постоянно)

```bash
cd /Users/a1111/Desktop/projects/Telegrambot
swift build
swift run NowmttBot
```



10. Создать пятую вкладку терминала Cmd + T и проверить проксирование через nginx:

```bash
curl -i http://127.0.0.1:8080/sora/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"https://sora.chatgpt.com/p/TEST"}}'
```



11. В этой же пятой вкладке проверить проксирование через ngrok:

(Сначала получи URL из вкладки, где запущен ngrok - строка "Forwarding https://xxxxx-xxxxx-xxxxx.ngrok-free.app")
(Или открой http://127.0.0.1:4040 в браузере для веб-интерфейса ngrok)
(Замени ВАШ-URL-ОТ-NGROK в команде ниже на реальный URL из ngrok)
(Эту вкладку можно закрыть после проверок)

```bash
curl -i https://ВАШ-URL-ОТ-NGROK.ngrok-free.app/sora/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"https://sora.chatgpt.com/p/TEST"}}'
```


12. В @botfather выбрать @roundvideobot / Soranowbot и далее "Bot settings" потом в "Menu button" нажать "Configure menu button" и вставить URL из ngrok



Вкладки терминала, которые должны оставаться открытыми для постоянной работы:

- NGINX: работает как системный сервис (НЕ требует открытой вкладки терминала)
- Playwright-сервис: работает в Docker (НЕ требует открытой вкладки терминала, можно закрыть после запуска)
- Вкладка 5 (шаг 5): ngrok с VPN (работает постоянно)
- Вкладка 8 (шаг 8): VideoServiceRunner (Roundsvideobot) (работает постоянно)
- Вкладка 9 (шаг 9): SoranowBot (работает постоянно)



Итого: 3 вкладки терминала должны быть открыты постоянно (ngrok, VideoServiceRunner, SoranowBot).
```
