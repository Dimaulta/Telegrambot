# Проверка общего проксирования
curl -i http://127.0.0.1:8080/sora/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"/start"}}'

# NowmttBot
curl -i http://127.0.0.1:8080/nowmtt/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"https://www.tiktok.com/@demo/video/123"}}'

# VeoNowBot (при наличии)
curl -i http://127.0.0.1:8080/veonow/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"Сгенерируй короткое видео"}}'

# BananaNowBot
curl -i http://127.0.0.1:8080/banananow/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"Сгенерируй яркий постер с бананом"}}'

# ContentFabrikaBot
curl -i http://127.0.0.1:8080/contentfabrika/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"/start"}}'
```

## Через ngrok (внешний URL)

Перед выполнением замени `ВАШ-URL-ОТ-NGROK` на адрес из вкладки с ngrok или с панели http://127.0.0.1:4040.

```bash
# SoranowBot
curl -i https://ВАШ-URL-ОТ-NGROK.ngrok-free.app/soranow/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"Сгенерируй видео с мигающим неоном"}}'

# NowmttBot
curl -i https://ВАШ-URL-ОТ-NGROK.ngrok-free.app/nowmtt/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"https://www.tiktok.com/@demo/video/123"}}'

# VeoNowBot (при наличии)
curl -i https://ВАШ-URL-ОТ-NGROK.ngrok-free.app/veonow/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"Сгенерируй короткое видео"}}'

# BananaNowBot
curl -i https://ВАШ-URL-ОТ-NGROK.ngrok-free.app/banananow/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"Создай атмосферную сцену с бананами"}}'

# ContentFabrikaBot
curl -i https://ВАШ-URL-ОТ-NGROK.ngrok-free.app/contentfabrika/webhook \
  -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":123},"text":"/start"}}'
```
