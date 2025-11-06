# Альтернативные решения для получения видео без ватермарки

## Текущая проблема
- `__NEXT_DATA__` не загружается даже после 50+ секунд ожидания
- API endpoints возвращают 404
- Все найденные ссылки имеют ватермарку (UUID начинается с `00000000-`)
- Токен сессии не помогает

## Возможные решения

### 1. Использование готовых сервисов через API

#### nosorawm.app API (если есть)
Если nosorawm.app предоставляет API, можно использовать его:
```javascript
// Пример использования (если API доступен)
const response = await fetch('https://nosorawm.app/api/get-video?url=' + encodeURIComponent(shareUrl));
const data = await response.json();
const videoUrl = data.videoUrl; // Ссылка без ватермарки
```

**Проверка:** Нужно посмотреть Network tab в DevTools при использовании nosorawm.app, чтобы увидеть, какие запросы они делают.

#### Другие сервисы
- Могут быть другие сервисы, которые предоставляют API
- Можно использовать их как fallback

### 2. Использование Puppeteer/Playwright с другими стратегиями

#### Стратегия: Ждать конкретного network request
Вместо ожидания `__NEXT_DATA__`, можно ждать конкретного network request к `videos.openai.com`:
```javascript
// Ждём запрос к videos.openai.com с UUID без ватермарки
const response = await page.waitForResponse(response => {
  return response.url().includes('videos.openai.com') && 
         response.url().includes('/az/files/') && 
         response.url().includes('/raw') &&
         !response.url().includes('/drvs/') &&
         !response.url().match(/\/az\/files\/00000000-/);
}, { timeout: 30000 });
```

#### Стратегия: Использовать CDP (Chrome DevTools Protocol)
Можно использовать CDP для более глубокого контроля:
```javascript
const client = await page.context().newCDPSession(page);
await client.send('Network.enable');
// Перехватываем все network requests более точно
```

### 3. Использование MCP серверов

#### Browser MCP Server
Можно использовать MCP сервер для браузера:
```javascript
// Пример использования MCP сервера
const mcpResponse = await mcpBrowser.navigate(url);
const videoUrl = await mcpBrowser.extractVideoUrl();
```

**Проблема:** Нужно найти или создать MCP сервер, который умеет работать с Sora.

#### Custom MCP Server
Можно создать свой MCP сервер, который:
- Использует Puppeteer/Playwright
- Имеет специальную логику для Sora
- Кэширует результаты

### 4. Анализ работы nosorawm.app

#### Что нужно сделать:
1. Открыть nosorawm.app в DevTools
2. Посмотреть Network tab
3. Найти, какие запросы они делают
4. Посмотреть, какие данные они получают
5. Воспроизвести их подход

#### Возможные подходы nosorawm.app:
- Используют другой endpoint API
- Используют GraphQL вместо REST
- Используют WebSocket для получения данных
- Используют другой метод извлечения данных из HTML
- Используют кэширование или прокси

### 5. Использование готовых библиотек

#### Возможные библиотеки:
- Могут быть готовые библиотеки для работы с Sora API
- Можно использовать их как fallback

### 6. Использование внешних сервисов

#### ScrapingBee / ScraperAPI
Уже есть в коде, но можно улучшить:
- Использовать их для получения `__NEXT_DATA__`
- Они могут обходить Cloudflare лучше

#### Другие сервисы
- Могут быть другие сервисы для рендеринга JS
- Можно использовать их как fallback

### 7. Прямое использование Sora API (если доступен)

#### Если есть публичный API:
```javascript
// Пример использования (если API доступен)
const response = await fetch('https://sora.chatgpt.com/api/videos/' + uuid, {
  headers: {
    'Authorization': 'Bearer ' + token
  }
});
```

**Проблема:** Нужно найти правильный endpoint и формат запроса.

### 8. Использование нейросетей для анализа

#### Можно использовать:
- Claude / GPT для анализа HTML и поиска паттернов
- Для понимания структуры данных
- Для генерации правильных запросов

**Проблема:** Это может быть медленно и дорого.

## Рекомендации

### Первым делом:
1. **Проанализировать nosorawm.app** - посмотреть, как они работают
2. **Попробовать использовать их подход** - воспроизвести их логику
3. **Использовать готовые сервисы** - если есть API

### Если не поможет:
1. **Создать свой MCP сервер** - для более глубокого контроля
2. **Использовать другие стратегии** - CDP, WebSocket и т.д.
3. **Использовать внешние сервисы** - ScrapingBee, ScraperAPI и т.д.

## Следующие шаги

1. Исправить ошибку с закрытием страницы (уже сделано)
2. Проанализировать nosorawm.app через DevTools
3. Попробовать использовать их подход
4. Если не поможет - создать MCP сервер или использовать другие методы

