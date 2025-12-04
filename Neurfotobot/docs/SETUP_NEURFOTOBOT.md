# Настройка внешних сервисов для Neurfotobot

Краткая инструкция по получению ключей и токенов для работы Neurfotobot.

> **Примечание:** Инструкция по созданию Telegram бота через @BotFather находится в основном [SETUP_GUIDE.md](../../docs/SETUP_GUIDE.md).

---

## Обзор необходимых сервисов

| Сервис | Что получить | Обязательность | Ссылка |
|--------|--------------|----------------|--------|
| **Replicate** | API токен, модель для обучения, модель для генерации | ✅ Обязательно | [replicate.com](https://replicate.com/) |
| **Supabase** | URL проекта, Service Role Key, имя bucket | ✅ Обязательно | [supabase.com](https://supabase.com/) |
| **Yandex Translate API** | API ключ | ✅ Обязательно | [console.cloud.yandex.ru](https://console.cloud.yandex.ru/) |
| **Google Vision API** | API ключ | ⚠️ Опционально | [console.cloud.google.com](https://console.cloud.google.com/) |
| **OpenAI Moderation API** | API ключ | ⚠️ Опционально | [platform.openai.com](https://platform.openai.com/) |

---

## Replicate

**Что нужно получить:**
- `REPLICATE_API_TOKEN` — API токен
- `REPLICATE_TRAINING_VERSION` — версия модели для обучения (например: `replicate/fast-flux-trainer:latest`)
- `REPLICATE_MODEL_OWNER` — твой username на Replicate
- `REPLICATE_MODEL_VERSION` — версия модели для генерации (например: `black-forest-labs/flux-1.1-pro:latest`)
- `REPLICATE_DESTINATION_MODEL_SLUG` — имя модели для сохранения обученных версий (без owner/)

**Ссылки:**
- [Регистрация](https://replicate.com/)
- [Настройка биллинга](https://replicate.com/account/billing) ⚠️ Требуется привязка карты
- [API токены](https://replicate.com/account/api-tokens)
- [Создание модели](https://replicate.com/create)
- [Модели для обучения](https://replicate.com/models?query=fast-flux-trainer)
- [Модели для генерации](https://replicate.com/models?query=flux)

**Краткая инструкция:**
1. Зарегистрируйся на [Replicate.com](https://replicate.com/)
2. Привяжи карту в [Billing](https://replicate.com/account/billing)
3. Создай API токен в [Account Settings → API Tokens](https://replicate.com/account/api-tokens)
4. Создай модель для хранения обученных версий в [Create Model](https://replicate.com/create)
5. Скопируй версию модели для обучения (например: `replicate/fast-flux-trainer:latest`)
6. Скопируй версию модели для генерации (например: `black-forest-labs/flux-1.1-pro:latest`)

---

## Supabase

**Что нужно получить:**
- `SUPABASE_URL` — URL проекта (формат: `https://xxxxx.supabase.co`)
- `SUPABASE_SERVICE_KEY` — Service Role Key (секретный ключ)
- `SUPABASE_BUCKET` — имя bucket в Storage

**Ссылки:**
- [Регистрация и создание проекта](https://supabase.com/)
- [Dashboard](https://app.supabase.com/)
- [Settings → API](https://app.supabase.com/project/_/settings/api)
- [Storage](https://app.supabase.com/project/_/storage/buckets)

**Краткая инструкция:**
1. Создай проект на [Supabase.com](https://supabase.com/)
2. Создай публичный bucket в Storage (например: `neurfoto-uploads`)
3. Настрой политики доступа для bucket (публичное чтение и загрузка)
4. Скопируй `Project URL` и `service_role` ключ из [Settings → API](https://app.supabase.com/project/_/settings/api)

---

## Yandex Translate API

**Что нужно получить:**
- `YANDEX_TRANSLATE_API_KEY` — API ключ (формат: `AQVNxxxxxxxxxxxxx`)
- `YANDEX_CLOUD_FOLDER_ID` — ID каталога (опционально, если один каталог)

**Ссылки:**
- [Yandex Cloud Console](https://console.cloud.yandex.ru/)
- [Создание платежного аккаунта](https://console.cloud.yandex.ru/billing)
- [Сервисные аккаунты](https://console.cloud.yandex.ru/iam/service-accounts)
- [Документация по созданию API-ключа](https://yandex.cloud/ru/docs/translate/operations/sa-api-key)

**Краткая инструкция:**
1. Зарегистрируйся в [Yandex Cloud](https://console.cloud.yandex.ru/)
2. Создай платежный аккаунт (требуется для работы API, но есть бесплатный лимит: 1М символов/день)
3. Создай сервисный аккаунт в [Service Accounts](https://console.cloud.yandex.ru/iam/service-accounts)
4. Назначь роль `ai.translate.user` сервисному аккаунту
5. Создай API-ключ с областью действия `yc.ai.translate.execute`

**Бесплатный лимит:** 1 миллион символов в сутки, до 10 миллионов в месяц

---

## Google Vision API (опционально)

**Что нужно получить:**
- `GOOGLE_VISION_API_KEY` — API ключ

**Ссылки:**
- [Google Cloud Console](https://console.cloud.google.com/)
- [Cloud Vision API](https://console.cloud.google.com/apis/library/vision.googleapis.com)
- [Credentials](https://console.cloud.google.com/apis/credentials)
- [Billing](https://console.cloud.google.com/billing)

**Краткая инструкция:**
1. Создай проект в [Google Cloud Console](https://console.cloud.google.com/)
2. Включи Cloud Vision API в [APIs & Services → Library](https://console.cloud.google.com/apis/library/vision.googleapis.com)
3. Настрой биллинг (требуется для работы API)
4. Создай API ключ в [APIs & Services → Credentials](https://console.cloud.google.com/apis/credentials)

**Тарифы:** $1.50 за 1000 запросов (первые 1000 запросов в месяц бесплатно)

> **Примечание:** Можно отключить через `DISABLE_SAFESEARCH=true` в `.env`

---

## OpenAI Moderation API (опционально)

**Что нужно получить:**
- `NEURFOTOBOT_OPENAI_API_KEY` — API ключ (формат: `sk-xxxxxxxxxxxxx`)

⚠️ **Важно:** Используй отдельный ключ для Neurfotobot (не `OPENAI_API_KEY`), чтобы избежать конфликтов с другими проектами.

**Ссылки:**
- [OpenAI Platform](https://platform.openai.com/)
- [API Keys](https://platform.openai.com/api-keys)
- [Billing](https://platform.openai.com/account/billing)
- [Moderation API Documentation](https://platform.openai.com/docs/guides/moderation)

**Краткая инструкция:**
1. Зарегистрируйся на [OpenAI Platform](https://platform.openai.com/)
2. Привяжи карту в [Billing](https://platform.openai.com/account/billing)
3. Создай API ключ в [API Keys](https://platform.openai.com/api-keys) с названием "Neurfotobot Moderation"

**Тарифы:** $0.10 за 1 миллион токенов

> **Примечание:** Можно отключить через `DISABLE_PROMPT_MODERATION=true` в `.env`

---

## Конфигурация переменных окружения

Добавь полученные ключи в `config/.env`:

```env
# ============================================
# NEURFOTOBOT – Нейрофотографии
# ============================================

# Telegram Bot Token (см. основной SETUP_GUIDE.md)
NEURFOTOBOT_TOKEN=1234567890:ABCdefGHIjklMNOpqrsTUVwxyz

# Replicate API
REPLICATE_API_TOKEN=r8_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx
REPLICATE_TRAINING_VERSION=replicate/fast-flux-trainer:latest
REPLICATE_MODEL_OWNER=your-username
REPLICATE_MODEL_VERSION=black-forest-labs/flux-1.1-pro:latest
REPLICATE_DESTINATION_MODEL_SLUG=neurfoto-models

# Supabase Storage
SUPABASE_URL=https://xxxxx.supabase.co
SUPABASE_SERVICE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
SUPABASE_BUCKET=neurfoto-uploads

# Yandex Translate API
YANDEX_TRANSLATE_API_KEY=AQVNxxxxxxxxxxxxx
# Опционально:
# YANDEX_CLOUD_FOLDER_ID=b1gxxxxxxxxxxxxx

# Google Vision API (опционально)
GOOGLE_VISION_API_KEY=AIzaSyxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# OpenAI Moderation API (опционально)
NEURFOTOBOT_OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Флаги для отключения функций (опционально)
DISABLE_SAFESEARCH=false          # Отключить модерацию фото
DISABLE_PROMPT_MODERATION=false    # Отключить модерацию промптов
DISABLE_TRANSLATION=false          # Отключить перевод промптов
KEEP_DATASETS_ON_FAILURE=false     # Оставлять датасеты при ошибках
```

---

## Таблица переменных окружения

### Обязательные переменные

| Переменная | Где получить |
|-----------|--------------|
| `NEURFOTOBOT_TOKEN` | [@BotFather](https://t.me/BotFather) (см. основной SETUP_GUIDE.md) |
| `REPLICATE_API_TOKEN` | [Replicate Account Settings](https://replicate.com/account/api-tokens) |
| `REPLICATE_TRAINING_VERSION` | Формат: `owner/model:version` (например: `replicate/fast-flux-trainer:latest`) |
| `REPLICATE_MODEL_OWNER` | Твой username на Replicate |
| `REPLICATE_MODEL_VERSION` | Формат: `owner/model:version` (например: `black-forest-labs/flux-1.1-pro:latest`) |
| `REPLICATE_DESTINATION_MODEL_SLUG` | Имя модели, созданной в Replicate (без owner/) |
| `SUPABASE_URL` | [Supabase Settings → API](https://app.supabase.com/project/_/settings/api) |
| `SUPABASE_SERVICE_KEY` | [Supabase Settings → API](https://app.supabase.com/project/_/settings/api) |
| `SUPABASE_BUCKET` | Имя bucket, созданного в Supabase Storage |
| `YANDEX_TRANSLATE_API_KEY` | [Yandex Cloud → Service Accounts → API Keys](https://console.cloud.yandex.ru/iam/service-accounts) |

### Опциональные переменные

| Переменная | Где получить |
|-----------|--------------|
| `GOOGLE_VISION_API_KEY` | [Google Cloud → Credentials](https://console.cloud.google.com/apis/credentials) |
| `NEURFOTOBOT_OPENAI_API_KEY` | [OpenAI Platform → API Keys](https://platform.openai.com/api-keys) |
| `YANDEX_CLOUD_FOLDER_ID` | [Yandex Cloud Console](https://console.cloud.yandex.ru/cloud) |
| `DISABLE_SAFESEARCH` | `true` для отключения модерации фото |
| `DISABLE_PROMPT_MODERATION` | `true` для отключения модерации промптов |
| `DISABLE_TRANSLATION` | `true` для отключения перевода промптов |
| `KEEP_DATASETS_ON_FAILURE` | `true` для отладки (оставляет датасеты при ошибках) |

---

## Дополнительные ресурсы

- [Документация Replicate API](https://replicate.com/docs)
- [Документация Supabase](https://supabase.com/docs)
- [Документация Yandex Translate API](https://yandex.cloud/ru/docs/translate/)
- [Документация Google Vision API](https://cloud.google.com/vision/docs)
- [Документация OpenAI Moderation API](https://platform.openai.com/docs/guides/moderation)

---

После настройки всех сервисов переходи к [QUICK_START.md](../../docs/QUICK_START.md) для запуска бота.
