#!/bin/bash

# Скрипт для настройки webhook'ов для всех ботов
# Загружает переменные из config/.env

# Загружаем переменные из .env
if [ -f "config/.env" ]; then
    export $(grep -v '^#' config/.env | xargs)
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
# WMMOVEBOT (Sora Watermark Removal)
# ============================================
if [ -z "$WMMOVEBOT_TOKEN" ]; then
    echo "⚠️ WMMOVEBOT_TOKEN не установлен, пропускаем..."
else
    echo "🔧 Настройка webhook для WmmoveBot..."
    echo "📡 URL: ${BASE_URL}/sora/webhook"
    
    curl -X POST "https://api.telegram.org/bot${WMMOVEBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/sora/webhook\"}"
    
    echo ""
    echo "✅ Webhook для WmmoveBot настроен!"
    echo "📋 Проверка:"
    curl "https://api.telegram.org/bot${WMMOVEBOT_TOKEN}/getWebhookInfo"
    echo ""
fi

# ============================================
# VIDEO_BOT (Video Processing)
# ============================================
if [ -z "$VIDEO_BOT_TOKEN" ]; then
    echo "⚠️ VIDEO_BOT_TOKEN не установлен, пропускаем..."
else
    echo "🔧 Настройка webhook для Video Bot..."
    echo "📡 URL: ${BASE_URL}/webhook"
    
    curl -X POST "https://api.telegram.org/bot${VIDEO_BOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/webhook\"}"
    
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
    
    curl -X POST "https://api.telegram.org/bot${NEURFOTOBOT_TOKEN}/setWebhook" \
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
    echo "📡 URL: ${BASE_URL}/webhook"
    
    curl -X POST "https://api.telegram.org/bot${GSFORTEXTBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/webhook\"}"
    
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
    
    curl -X POST "https://api.telegram.org/bot${NOWMTTBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/nowmtt/webhook\"}"
    
    echo ""
    echo "✅ Webhook для NowmttBot настроен!"
    echo "📋 Проверка:"
    curl "https://api.telegram.org/bot${NOWMTTBOT_TOKEN}/getWebhookInfo"
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

    curl -X POST "https://api.telegram.org/bot${SORANOWBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/soranow/webhook\"}"

    echo ""
    echo "✅ Webhook для SoranowBot настроен!"
    echo "📋 Проверка:"
    curl "https://api.telegram.org/bot${SORANOWBOT_TOKEN}/getWebhookInfo"
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
        payload="${payload},\"secret_token\":\"${VEONOWBOT_WEBHOOK_SECRET}\""
    fi
    payload="${payload}}"

    curl -X POST "https://api.telegram.org/bot${VEONOWBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "${payload}"

    echo ""
    echo "✅ Webhook для VeoNowBot настроен!"
    echo "📋 Проверка:"
    curl "https://api.telegram.org/bot${VEONOWBOT_TOKEN}/getWebhookInfo"
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

    curl -X POST "https://api.telegram.org/bot${BANANANOWBOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/json" \
      -d "{\"url\":\"${BASE_URL}/banananow/webhook\"}"

    echo ""
    echo "✅ Webhook для BananaNowBot настроен!"
    echo "📋 Проверка:"
    curl "https://api.telegram.org/bot${BANANANOWBOT_TOKEN}/getWebhookInfo"
    echo ""
fi

echo "🎉 Готово! Все webhook'и настроены."

# ============================================
# Другие боты (если нужны)
# ============================================

# VIDEO_BOT (Video Processing)
# curl -X POST "https://api.telegram.org/botVIDEO_BOT_TOKEN/setWebhook" \
#   -H "Content-Type: application/json" \
#   -d '{"url":"https://your-domain.com/webhook"}'

# NEURFOTOBOT (AI Photo Generation)
# curl -X POST "https://api.telegram.org/botNEURFOTOBOT_TOKEN/setWebhook" \
#   -H "Content-Type: application/json" \
#   -d '{"url":"https://your-domain.com/webhook"}'

# GSFORTEXTBOT (Voice to Text)
# curl -X POST "https://api.telegram.org/botGSFORTEXTBOT_TOKEN/setWebhook" \
#   -H "Content-Type: application/json" \
#   -d '{"url":"https://your-domain.com/webhook"}'

