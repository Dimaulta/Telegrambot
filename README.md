# telegramBot01

💧 A project built with the Vapor web framework.

## Getting Started

To build the project using the Swift Package Manager, run the following command in the terminal from the root of the project:
```bash
swift build
```

To run the project and start the server, use the following command:
```bash
swift run
```

To execute tests, use the following command:
```bash
swift test
```

### See more

- [Vapor Website](https://vapor.codes)
- [Vapor Documentation](https://docs.vapor.codes)
- [Vapor GitHub](https://github.com/vapor)
- [Vapor Community](https://github.com/vapor-community)

## TEMP_DIR — настройка временной папки

Для хранения временных видеофайлов сервис использует переменную окружения `TEMP_DIR`. Укажи путь к папке, где будут храниться временные файлы (абсолютный или относительный). Если переменная не задана, используется путь по умолчанию: `Resources/temporaryvideoFiles/`.

**Пример для .env:**
```
TEMP_DIR=video-service/Resources/temporaryvideoFiles/
```

- Для локального запуска на MacBook: можно использовать относительный путь, если сервер стартует из корня проекта.
- Для Docker/VPS: рекомендуется абсолютный путь, например `/app/Resources/temporaryvideoFiles/`.

**Важно:**
- Папка будет создана автоматически, если не существует.
- Не забудь добавить TEMP_DIR в свой `.env` (или `.env.example` для шаблона).
