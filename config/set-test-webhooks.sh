#!/bin/bash

# Скрипт для настройки webhook'ов для тестовых ботов
# Использование: ./config/set-test-webhooks.sh
# 
# Важно: Использует те же имена переменных, что и продакшн
# (без префикса TEST), т.к. код через CI/CD не должен иметь TEST в переменных

set -a
source config/.env
set +a

if [ -z "$BASE_URL" ]; then
    echo "❌ BASE_URL не установлен в config/.env"
    exit 1
fi

echo "=== Установка webhook для тестовых ботов ==="
echo ""
echo "🌐 BASE_URL: ${BASE_URL}"
echo ""

set_webhook() {
    local bot_name=$1
    local token=$2
    local webhook_path=$3
    
    if [ -z "$token" ]; then
        echo "⚠️  Токен для $bot_name не найден, пропускаю..."
        return
    fi
    
    local webhook_url="${BASE_URL}${webhook_path}"
    echo "🔧 Настройка webhook для $bot_name..."
    echo "📡 URL: ${webhook_url}"
    
    result=$(curl -s -X POST "https://api.telegram.org/bot${token}/setWebhook" \
        -H "Content-Type: application/json" \
        -d "{\"url\":\"${webhook_url}\"}")
    
    if echo "$result" | grep -q '"ok":true'; then
        echo "✅ Webhook для $bot_name успешно установлен"
        echo "📋 Проверка:"
        curl -s "https://api.telegram.org/bot${token}/getWebhookInfo" | python3 -m json.tool 2>/dev/null | grep -E "url|pending_update_count" || echo "$result"
    else
        echo "❌ Ошибка при установке webhook для $bot_name:"
        echo "$result" | python3 -m json.tool 2>/dev/null || echo "$result"
    fi
    echo ""
}

# Устанавливаем webhook для каждого тестового бота
# Используем актуальные пути из services.json и set-webhooks.sh

set_webhook "testnowcontrollerbot" "${NOWCONTROLLERBOT_TOKEN:-}" "/nowcontroller/webhook"
set_webhook "testneurfotobot" "${NEURFOTOBOT_TOKEN:-}" "/neurfoto/webhook"
set_webhook "testcontentfabrikabot" "${CONTENTFABRIKABOT_TOKEN:-}" "/contentfabrika/webhook"
set_webhook "testpereskaznowbot" "${PERESKAZNOWBOT_TOKEN:-}" "/pereskaznow/webhook"
set_webhook "testroundsvideobot" "${VIDEO_BOT_TOKEN:-}" "/rounds/webhook"
set_webhook "testfilenowbot" "${FILENOWBOT_TOKEN:-}" "/filenow/webhook"
set_webhook "testgolosnowbot" "${GOLOSNOWBOT_TOKEN:-}" "/golosnow/webhook"

echo "=== Готово ==="
echo ""
echo "Все webhook для тестовых ботов установлены на ${BASE_URL}"
