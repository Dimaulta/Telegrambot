#!/bin/bash

# Скрипт для удаления webhook у тестовых ботов
# Использование: ./config/delete-test-webhooks.sh
# 
# Важно: Использует те же имена переменных, что и продакшн
# (без префикса TEST), т.к. код через CI/CD не должен иметь TEST в переменных

set -a
source config/.env
set +a

echo "=== Удаление webhook для тестовых ботов ==="
echo ""
echo "Используются токены из config/.env (те же имена, что и в продакшн)"
echo ""

# Список тестовых ботов и их токенов
# Используем те же имена переменных, что и в продакшн

delete_webhook() {
    local bot_name=$1
    local token=$2
    
    if [ -z "$token" ]; then
        echo "⚠️  Токен для $bot_name не найден, пропускаю..."
        return
    fi
    
    echo "🗑️  Удаляю webhook для $bot_name..."
    result=$(curl -s -X POST "https://api.telegram.org/bot${token}/deleteWebhook")
    
    if echo "$result" | grep -q '"ok":true'; then
        echo "✅ Webhook для $bot_name успешно удален"
    else
        echo "❌ Ошибка при удалении webhook для $bot_name:"
        echo "$result" | python3 -m json.tool 2>/dev/null || echo "$result"
    fi
    echo ""
}

# Удаляем webhook для каждого тестового бота
delete_webhook "testnowcontrollerbot" "${NOWCONTROLLERBOT_TOKEN:-}"
delete_webhook "testneurfotobot" "${NEURFOTOBOT_TOKEN:-}"
delete_webhook "testcontentfabrikabot" "${CONTENTFABRIKABOT_TOKEN:-}"
delete_webhook "testpereskaznowbot" "${PERESKAZNOWBOT_TOKEN:-}"
delete_webhook "testroundsvideobot" "${VIDEO_BOT_TOKEN:-}"
delete_webhook "testfilenowbot" "${FILENOWBOT_TOKEN:-}"
delete_webhook "testgolosnowbot" "${GOLOSNOWBOT_TOKEN:-}"

echo "=== Готово ==="
echo ""
echo "Проверка: напиши /start тестовому боту - ответ должен прийти от локального процесса"
