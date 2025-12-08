#!/bin/bash

# Скрипт для настройки webhook'ов для всех ботов
# Загружает переменные из config/.env

# Загружаем переменные из .env (правильная обработка комментариев)
if [ -f "config/.env" ]; then
    # Убираем комментарии (всё после #), пустые строки и строки, начинающиеся с #
    set -a
    while IFS= read -r line; do
        # Пропускаем пустые строки и строки, начинающиеся с #
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Убираем комментарии в конце строки
        line="${line%%#*}"
        # Убираем пробелы в начале и конце
        line=$(echo "$line" | xargs)
        # Экспортируем только если есть знак =
        [[ "$line" == *"="* ]] && export "$line"
    done < config/.env
    set +a
else
    echo "❌ Файл config/.env не найден!"
    exit 1
fi

if [ -z "$BASE_URL" ]; then
    echo "❌ BASE_URL не установлен в config/.env"
    echo "💡 Установите URL туннеля (например: https://cyan-snakes-hope.loca.lt)"
    exit 1
fi

echo "🌐 BASE_URL: ${BASE_URL}"
echo ""

# ============================================
# NOWCONTROLLERBOT (Управление отправкой сообщений в боты NowBots)
# ============================================
if [ -z "$NOWCONTROLLERBOT_TOKEN" ]; then
    echo "⚠️ NOWCONTROLLERBOT_TOKEN не установлен, пропускаем..."
else
    echo "🔧 Настройка webhook для NowControllerBot..."
    echo "📡 URL: ${BASE_URL}/nowcontroller/webhook"
    
    curl -sS -X POST "https://api.telegram.org/bot${NOWCONTROLLERBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/nowcontroller/webhook\"}"
    
    echo ""
    echo "✅ Webhook для NowControllerBot настроен!"
    echo "📋 Проверка:"
    curl -sS "https://api.telegram.org/bot${NOWCONTROLLERBOT_TOKEN}/getWebhookInfo"
    echo ""
    echo ""
fi

# ============================================
# VIDEO_BOT (Video Processing)
# ============================================
if [ -z "$VIDEO_BOT_TOKEN" ]; then
    echo "⚠️ VIDEO_BOT_TOKEN не установлен, пропускаем..."
else
    echo "🔧 Настройка webhook для Video Bot..."
    echo "📡 URL: ${BASE_URL}/rounds/webhook"
    
    curl -sS -X POST "https://api.telegram.org/bot${VIDEO_BOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/rounds/webhook\"}"
    
    echo ""
    echo "✅ Webhook для Video Bot настроен!"
    echo ""
fi

# ============================================
# NEURFOTOBOT (AI Photo Generation)
# ============================================
if [ -z "$NEURFOTOBOT_TOKEN" ]; then
    echo "⚠️ NEURFOTOBOT_TOKEN не установлен, пропускаем..."
else
    echo "🔧 Настройка webhook для Neurfotobot..."
    echo "📡 URL: ${BASE_URL}/neurfoto/webhook"
    
    curl -sS -X POST "https://api.telegram.org/bot${NEURFOTOBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/neurfoto/webhook\"}"
    
    echo ""
    echo "✅ Webhook для Neurfotobot настроен!"
    echo ""
fi

# ============================================
# GSFORTEXTBOT (Voice to Text)
# ============================================
if [ -z "$GSFORTEXTBOT_TOKEN" ]; then
    echo "⚠️ GSFORTEXTBOT_TOKEN не установлен, пропускаем..."
else
    echo "🔧 Настройка webhook для GS For Text Bot..."
    echo "📡 URL: ${BASE_URL}/gs/text/webhook"
    
    curl -sS -X POST "https://api.telegram.org/bot${GSFORTEXTBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/gs/text/webhook\"}"
    
    echo ""
    echo "✅ Webhook для GS For Text Bot настроен!"
    echo ""
fi

# ============================================
# NOWMTTBOT (TikTok Video Downloader)
# ============================================
if [ -z "$NOWMTTBOT_TOKEN" ]; then
    echo "⚠️ NOWMTTBOT_TOKEN не установлен, пропускаем..."
else
    echo "🔧 Настройка webhook для NowmttBot..."
    echo "📡 URL: ${BASE_URL}/nowmtt/webhook"
    
    curl -sS -X POST "https://api.telegram.org/bot${NOWMTTBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/nowmtt/webhook\"}"
    
    echo ""
    echo "✅ Webhook для NowmttBot настроен!"
    echo "📋 Проверка:"
    curl -sS "https://api.telegram.org/bot${NOWMTTBOT_TOKEN}/getWebhookInfo"
    echo ""
    echo ""
fi

# ============================================
# SORANOWBOT (Video Generation via external API)
# ============================================
if [ -z "$SORANOWBOT_TOKEN" ]; then
    echo "⚠️ SORANOWBOT_TOKEN не установлен, пропускаем..."
else
    echo "🔧 Настройка webhook для SoranowBot..."
    echo "📡 URL: ${BASE_URL}/soranow/webhook"

    curl -sS -X POST "https://api.telegram.org/bot${SORANOWBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/soranow/webhook\"}"

    echo ""
    echo "✅ Webhook для SoranowBot настроен!"
    echo "📋 Проверка:"
    curl -sS "https://api.telegram.org/bot${SORANOWBOT_TOKEN}/getWebhookInfo"
    echo ""
    echo ""
fi

# ============================================
# VEONOWBOT (Veo 3 Video Generation)
# ============================================
if [ -z "$VEONOWBOT_TOKEN" ]; then
    echo "⚠️ VEONOWBOT_TOKEN не установлен, пропускаем..."
else
    echo "🔧 Настройка webhook для VeoNowBot..."
    echo "📡 URL: ${BASE_URL}/veonow/webhook"

    payload="{\"url\":\"${BASE_URL}/veonow/webhook\""
    if [ -n "$VEONOWBOT_WEBHOOK_SECRET" ]; then
        # Проверяем, что secret token содержит только допустимые символы
        if [[ "$VEONOWBOT_WEBHOOK_SECRET" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            payload="${payload},\"secret_token\":\"${VEONOWBOT_WEBHOOK_SECRET}\""
        else
            echo "⚠️ VEONOWBOT_WEBHOOK_SECRET содержит недопустимые символы, используем без secret token"
        fi
    fi
    payload="${payload}}"

    curl -sS -X POST "https://api.telegram.org/bot${VEONOWBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "${payload}"

    echo ""
    echo "✅ Webhook для VeoNowBot настроен!"
    echo "📋 Проверка:"
    curl -sS "https://api.telegram.org/bot${VEONOWBOT_TOKEN}/getWebhookInfo"
    echo ""
    echo ""
fi

# ============================================
# BANANANOWBOT (Nano Banana Media)
# ============================================
if [ -z "$BANANANOWBOT_TOKEN" ]; then
    echo "⚠️ BANANANOWBOT_TOKEN не установлен, пропускаем..."
else
    echo "🔧 Настройка webhook для BananaNowBot..."
    echo "📡 URL: ${BASE_URL}/banananow/webhook"

    curl -sS -X POST "https://api.telegram.org/bot${BANANANOWBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/banananow/webhook\"}"

    echo ""
    echo "✅ Webhook для BananaNowBot настроен!"
    echo "📋 Проверка:"
    curl -sS "https://api.telegram.org/bot${BANANANOWBOT_TOKEN}/getWebhookInfo"
    echo ""
    echo ""
fi

# ============================================
# CONTENTFABRIKABOT (AI Content Generator)
# ============================================
if [ -z "$CONTENTFABRIKABOT_TOKEN" ]; then
    echo "⚠️ CONTENTFABRIKABOT_TOKEN не установлен, пропускаем..."
else
    echo "🔧 Настройка webhook для ContentFabrikaBot..."
    echo "📡 URL: ${BASE_URL}/contentfabrika/webhook"

    curl -sS -X POST "https://api.telegram.org/bot${CONTENTFABRIKABOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/contentfabrika/webhook\"}"

    echo ""
    echo "✅ Webhook для ContentFabrikaBot настроен!"
    echo "📋 Проверка:"
    curl -sS "https://api.telegram.org/bot${CONTENTFABRIKABOT_TOKEN}/getWebhookInfo"
    echo ""
    echo ""
fi

echo "🎉 Готово! Все webhook'и настроены."
