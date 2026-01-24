# Проверка общего проксирования (NowControllerBot)
curl -i http://127.0.0.1:8080/nowcontroller/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"/start"}}'

# FileNowBot
curl -i http://127.0.0.1:8080/filenow/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"https://www.tiktok.com/@demo/video/123"}}'

# GolosNowBot (при наличии)
curl -i http://127.0.0.1:8080/golosnow/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"Озвучь этот текст"}}'

# AntispamNowBot (при наличии)
curl -i http://127.0.0.1:8080/antispamnow/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"/start"}}'

# ContentFabrikaBot
curl -i http://127.0.0.1:8080/contentfabrika/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"/start"}}'
```

## Через ngrok (внешний URL)

Перед выполнением замени `ВАШ-URL-ОТ-NGROK` на адрес из вкладки с ngrok или с панели http://127.0.0.1:4040.

```bash
# NowControllerBot
curl -i https://ВАШ-URL-ОТ-NGROK.ngrok-free.app/nowcontroller/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"/start"}}'

# FileNowBot
curl -i https://ВАШ-URL-ОТ-NGROK.ngrok-free.app/filenow/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"https://www.tiktok.com/@demo/video/123"}}'

# GolosNowBot (при наличии)
curl -i https://ВАШ-URL-ОТ-NGROK.ngrok-free.app/golosnow/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"Озвучь этот текст"}}'

# AntispamNowBot (при наличии)
curl -i https://ВАШ-URL-ОТ-NGROK.ngrok-free.app/antispamnow/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"/start"}}'

# ContentFabrikaBot
curl -i https://ВАШ-URL-ОТ-NGROK.ngrok-free.app/contentfabrika/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"/start"}}'
```
