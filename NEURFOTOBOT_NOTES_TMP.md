# Временные заметки для агента по Neurfotobot

- Добавлен SupabaseKeepAliveService: ping при старте и раз в 5 дней к Storage API, логирует предупреждения если проект на паузе
- SupabaseStorageClient: метод ping, общий executeWithRetry, retry с задержками для upload/download, таймауты 30с (upload/download) и 15с (ping)
- NeurfotobotController: upload в Supabase с retry и мягким сообщением пользователю при неудаче, класс помечен Sendable чтобы убрать варнинги
- configure.swift: запуск keep-alive сервисов при старте
- PhotoCleanupService: убран лишний do-catch, логика проверки подписки через MonetizationService сохранена
- DatasetBuilder: обновлен инициализатор Archive на throwing вариант
- Документация: в SETUP_NEURFOTOBOT.md добавлено предупреждение про автопаузу Supabase на фриплане и варианты обхода; в QUICK_START.md добавлено предупреждение о запросе прав на управление Terminal.app с картинкой MacOSterminal-rights.png; ARCHITECTURE.md статусы синхронизированы (PereskazNowBot MVP)

Удалить файл после передачи заметок

