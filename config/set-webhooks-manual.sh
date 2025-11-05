#!/bin/bash

# Ручная настройка webhook'ов (как раньше)
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
    exit 1
fi

echo "🌐 BASE_URL: ${BASE_URL}"
echo ""

# SoranowBot
curl -sS -X POST "https://api.telegram.org/bot${SORANOWBOT_TOKEN}/setWebhook" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"${BASE_URL}/sora/webhook\"}"

# Video Bot
curl -sS -X POST "https://api.telegram.org/bot${VIDEO_BOT_TOKEN}/setWebhook" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"${BASE_URL}/rounds/webhook\"}"

# GS For Text Bot
curl -sS -X POST "https://api.telegram.org/bot${GSFORTEXTBOT_TOKEN}/setWebhook" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"${BASE_URL}/gs/text/webhook\"}"

# Neurfotobot
curl -sS -X POST "https://api.telegram.org/bot${NEURFOTOBOT_TOKEN}/setWebhook" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"${BASE_URL}/neurfoto/webhook\"}"

echo ""
echo "✅ Все webhook'и настроены!"

