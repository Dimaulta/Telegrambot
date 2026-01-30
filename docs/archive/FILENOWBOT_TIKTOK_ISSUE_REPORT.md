# Отчёт: Проблема с загрузкой TikTok видео в filenowbot

**Дата:** 30 января 2026  
**Бот:** filenowbot  
**Проблема:** Все провайдеры TikTok не могут загрузить видео, возвращаются ошибки

---

## Описание проблемы

При попытке скачать TikTok видео через filenowbot все провайдеры возвращают ошибки. Последняя попытка была с URL: `https://www.tiktok.com/t/ZThyUEeKS/`

### Ошибка в логах:
```
[ ERROR ] ❌ Error processing TikTok video: Abort.400: Failed to resolve video URL from all providers
```

---

## Статус провайдеров

### 1. TikWM ✅ (Частично работает)
- **HTTP статус:** 200 OK
- **Проблема:** Парсинг ответа не работает
- **Детали:**
  - Сервис возвращает валидный JSON с полями `hdplay` и `play`
  - При проверке через curl ответ корректный
  - В логах бота: `TikWM invalid response snippet: ` (пустая строка)
  - **Вывод:** Проблема в чтении body ответа в Vapor, а не в самом провайдере

**Пример успешного ответа TikWM:**
```json
{
  "code": 0,
  "msg": "success",
  "data": {
    "hdplay": "https://v16m-default.tiktokcdn.com/...",
    "play": "https://v16m.tiktokcdn.com/..."
  }
}
```

### 2. TiklyDown ❌ (Недоступен)
- **HTTP статус:** Connection failed (000)
- **Ошибка:** `NIOPosix.NIOConnectionError error 1`
- **Вывод:** Сервис недоступен или блокирует запросы

### 3. Tikmate ❌ (Ошибка 400)
- **HTTP статус:** 400 Bad Request
- **Ошибка:** `Tikmate status 400`
- **Вывод:** Сервис отклоняет запросы (возможно, изменился API или требуется авторизация)

### 4. SnapTik ❌ (Ошибка 404)
- **HTTP статус:** 404 Not Found
- **Ошибка:** `SnapTik status 404`
- **Endpoint:** `https://snaptik.app/api/ajaxSearch`
- **Вывод:** Endpoint не найден, возможно API изменился

### 5. SSSTik ❌ (Ошибка 404)
- **HTTP статус:** 404 Not Found
- **Ошибка:** `SSSTik status 404`
- **Endpoint:** `https://ssstik.io/api?url=...`
- **Вывод:** Endpoint не найден, возможно API изменился

---

## Технические детали

### Файл с логикой: `filenowbot/Sources/App/Internal/TikTokResolver.swift`

**Проблемный код для TikWM (строки 150-166):**
```swift
let res = try await makeRequest(uri: uri, headers: headers, providerName: "TikWM")
guard let body = res.body else { throw Abort(.badRequest, reason: "TikWM empty response") }
let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
do {
    struct TikWMResponse: Decodable { let code: Int; let data: TikWMData? }
    struct TikWMData: Decodable { let hdplay: String?; let play: String? }
    let decoded = try JSONDecoder().decode(TikWMResponse.self, from: data)
    guard decoded.code == 0, let d = decoded.data else { throw Abort(.badRequest, reason: "TikWM bad code") }
    if let hd = d.hdplay, !hd.isEmpty { return hd }
    if let play = d.play, !play.isEmpty { return play }
    throw Abort(.badRequest, reason: "TikWM no playable url")
} catch {
    if let bodyString = String(data: data, encoding: .utf8) {
        logger.warning("TikWM invalid response snippet: \(bodyString.prefix(200))")
    }
    throw Abort(.badRequest, reason: "TikWM invalid response format")
}
```

**Проблема:** `body.getData()` возвращает пустые данные, хотя сервис отвечает корректно.

### Логи из контейнера:
```
[ INFO ] TikWM request: https://www.tikwm.com/api/?url=https://www.tiktok.com/t/ZThyUEeKS/&hd=1
[ WARNING ] TikWM invalid response snippet: 
[ WARNING ] Provider failed: Abort.400: TikWM invalid response format
[ INFO ] TiklyDown request: https://api.tiklydown.me/api/download?url=https://www.tiktok.com/t/ZThyUEeKS/
[ WARNING ] Provider failed: The operation could not be completed. (NIOPosix.NIOConnectionError error 1.)
[ INFO ] Tikmate request: https://api.tikmate.app/api/lookup?url=https://www.tiktok.com/t/ZThyUEeKS/
[ WARNING ] Provider failed: Abort.400: Tikmate status 400
[ WARNING ] Provider failed: Abort.400: SnapTik status 404
[ WARNING ] Provider failed: Abort.400: SSSTik status 404
[ ERROR ] ❌ Error processing TikTok video: Abort.400: Failed to resolve video URL from all providers
```

---

## Рекомендации по исправлению

### Приоритет 1: Исправить чтение body для TikWM

**Проблема:** В Vapor 4+ чтение body из `ClientResponse` может требовать другого подхода.

**Варианты решения:**

1. **Использовать `body.collect()` для асинхронного чтения:**
```swift
let body = try await res.body.collect()
let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
```

2. **Использовать `body.readableBytes` и `body.readString()`:**
```swift
guard let body = res.body else { throw Abort(.badRequest, reason: "TikWM empty response") }
let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
// Или
let bodyString = body.readString(length: body.readableBytes) ?? ""
let data = bodyString.data(using: .utf8) ?? Data()
```

3. **Добавить детальное логирование для диагностики:**
```swift
logger.info("TikWM response status: \(res.status)")
logger.info("TikWM body readableBytes: \(res.body?.readableBytes ?? 0)")
if let body = res.body {
    let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
    logger.info("TikWM body data size: \(data.count)")
    if let bodyString = String(data: data, encoding: .utf8) {
        logger.info("TikWM body preview: \(bodyString.prefix(500))")
    }
}
```

### Приоритет 2: Обновить/заменить неработающие провайдеры

1. **TiklyDown** - проверить доступность, возможно добавить альтернативный endpoint
2. **Tikmate** - проверить документацию API, возможно требуется обновление формата запроса
3. **SnapTik** - найти актуальный endpoint или удалить из списка
4. **SSSTik** - найти актуальный endpoint или удалить из списка

### Приоритет 3: Добавить новые провайдеры

Рассмотреть альтернативные сервисы для скачивания TikTok:
- `https://api16-normal-c-useast1a.tiktokv.com/aweme/v1/feed/` (официальный API, требует токен)
- Другие публичные API сервисы

---

## Тестирование

После исправления TikWM проверить:
1. Успешная загрузка TikTok видео через TikWM
2. Логи показывают корректный body ответа
3. Видео успешно скачивается и отправляется пользователю

---

## Дополнительная информация

- **Контейнер:** `telegrambot_filenowbot`
- **Последние логи:** `docker compose -f docker-compose.prod.yml logs --tail=100 filenowbot`
- **Файл с логикой:** `filenowbot/Sources/App/Internal/TikTokResolver.swift`
- **Контроллер:** `filenowbot/Sources/App/Controllers/FileNowBotController.swift`

---

## Команды для проверки

```bash
# Проверить доступность TikWM
curl -s "https://www.tikwm.com/api/?url=https://www.tiktok.com/t/ZThyUEeKS/&hd=1" | jq '.data | {hdplay, play}'

# Посмотреть логи filenowbot
docker compose -f docker-compose.prod.yml logs --tail=100 --since=1h filenowbot

# Проверить статус контейнера
docker compose -f docker-compose.prod.yml ps filenowbot
```
