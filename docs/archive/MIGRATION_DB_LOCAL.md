# 🗄️ Локальная миграция базы данных после переименования ботов

## 📋 Что нужно сделать локально

После того, как другой агент выполнил миграцию `gsfortextbot` → `golosnowbot`, нужно обновить локальную базу данных `config/monetization.sqlite`.

---

## 🔍 Текущее состояние БД

В базе данных есть следующие записи, которые нужно обновить:

### Таблица `bot_settings`:

**Текущие записи:**
- `gsfortextbot` - нужно обновить на `golosnowbot`
- `golosnowbot` - старая запись (пустая/в разработке), нужно удалить или обновить
- `nowmttbot` - старая запись, нужно удалить (уже мигрирована в `filenowbot`)

---

## ✅ SQL команды для локальной миграции

**Важно:** `bot_name` является PRIMARY KEY, поэтому нельзя просто обновить запись, если ключ уже существует.

Выполни эти команды в терминале:

```bash
cd /Users/a1111/Desktop/projects/Telegrambot

# 1. Сначала удалить старую запись golosnowbot (пустая/в разработке)
sqlite3 config/monetization.sqlite "DELETE FROM bot_settings WHERE bot_name = 'golosnowbot';"

# 2. Обновить gsfortextbot → golosnowbot
sqlite3 config/monetization.sqlite "UPDATE bot_settings SET bot_name = 'golosnowbot' WHERE bot_name = 'gsfortextbot';"

# 3. Удалить старую запись nowmttbot (уже мигрирована в filenowbot)
sqlite3 config/monetization.sqlite "DELETE FROM bot_settings WHERE bot_name = 'nowmttbot';"

# 4. Проверить результат
sqlite3 config/monetization.sqlite "SELECT bot_name, require_subscription, require_all_channels FROM bot_settings ORDER BY bot_name;"
```

---

## 🔄 Альтернативный вариант (если нужно сохранить настройки)

Если в старой записи `golosnowbot` есть важные настройки, которые нужно сохранить:

```bash
# 1. Сначала обновим gsfortextbot → golosnowbot
sqlite3 config/monetization.sqlite "UPDATE bot_settings SET bot_name = 'golosnowbot' WHERE bot_name = 'gsfortextbot';"

# 2. Проверим, есть ли дубликаты
sqlite3 config/monetization.sqlite "SELECT * FROM bot_settings WHERE bot_name = 'golosnowbot';"

# 3. Если есть две записи, объединим их (оставим настройки из новой миграции)
# Удалим старую запись golosnowbot
sqlite3 config/monetization.sqlite "DELETE FROM bot_settings WHERE bot_name = 'golosnowbot' AND rowid NOT IN (SELECT MAX(rowid) FROM bot_settings WHERE bot_name = 'golosnowbot');"

# 4. Удалить nowmttbot
sqlite3 config/monetization.sqlite "DELETE FROM bot_settings WHERE bot_name = 'nowmttbot';"
```

---

## 📝 Проверка после миграции

После выполнения команд проверь результат:

```bash
# Показать все боты
sqlite3 config/monetization.sqlite "SELECT bot_name, require_subscription, require_all_channels FROM bot_settings ORDER BY bot_name;"

# Должно быть:
# - contentfabrikabot
# - filenowbot (вместо nowmttbot)
# - golosnowbot (вместо gsfortextbot)
# - neurfotobot
# - pereskaznowbot
# - roundsvideobot
```

---

## ⚠️ Важно

1. **Делай backup перед миграцией:**
   ```bash
   cp config/monetization.sqlite config/monetization.sqlite.backup
   ```

2. **Проверь, что бот golosnowbot работает** после миграции

3. **На VPS нужно будет выполнить аналогичные команды** (но там это должен сделать агент на VPS)

---

## 🎯 Итоговые команды (все вместе)

```bash
cd /Users/a1111/Desktop/projects/Telegrambot

# Backup
cp config/monetization.sqlite config/monetization.sqlite.backup

# Миграция (порядок важен!)
sqlite3 config/monetization.sqlite "
  -- 1. Удалить старую запись golosnowbot (пустая/в разработке)
  DELETE FROM bot_settings WHERE bot_name = 'golosnowbot';
  
  -- 2. Обновить gsfortextbot → golosnowbot
  UPDATE bot_settings SET bot_name = 'golosnowbot' WHERE bot_name = 'gsfortextbot';
  
  -- 3. Удалить старую запись nowmttbot (уже мигрирована в filenowbot)
  DELETE FROM bot_settings WHERE bot_name = 'nowmttbot';
"

# Проверка
sqlite3 config/monetization.sqlite "SELECT bot_name, require_subscription, require_all_channels FROM bot_settings ORDER BY bot_name;"
```

---

**Дата создания:** 2025-01-24  
**Для миграции:** gsfortextbot → golosnowbot (локально)
