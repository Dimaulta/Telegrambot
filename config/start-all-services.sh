#!/bin/bash

# Скрипт для автоматического запуска всех сервисов в отдельных вкладках Terminal.app
# Запускает NowControllerBot первым (для инициализации БД), затем остальные MVP боты

# Получаем путь к директории проекта (откуда запущен скрипт)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Задержка между открытием вкладок (в секундах)
DELAY_BETWEEN_TABS=2

# Функция для открытия новой вкладки и выполнения команды
open_terminal_tab() {
    local service_name="$1"
    local command="$2"
    
    echo "🚀 Запускаю $service_name..."
    
    # Экранируем двойные кавычки и обратные слеши для AppleScript
    local escaped_command=$(echo "$command" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    
    # Открываем новую вкладку в Terminal.app и выполняем команду
    # do script без указания окна автоматически создаёт новую вкладку
    osascript <<EOF
tell application "Terminal"
    activate
    do script "$escaped_command"
end tell
EOF
    
    # Задержка перед открытием следующей вкладки
    sleep $DELAY_BETWEEN_TABS
}

# Проверяем наличие .env файла
if [ ! -f "$PROJECT_DIR/config/.env" ]; then
    echo "❌ Файл config/.env не найден!"
    echo "💡 Создай config/.env на основе config/env.example"
    exit 1
fi

echo "📦 Проект: $PROJECT_DIR"
echo "⏱️  Задержка между вкладками: ${DELAY_BETWEEN_TABS} сек"
echo ""

# Загружаем переменные окружения для проверки токенов
set -a
source "$PROJECT_DIR/config/.env" 2>/dev/null || {
    echo "⚠️  Не удалось загрузить config/.env, но продолжаем запуск..."
}
set +a

# 1. NowControllerBot (запускается первым для инициализации БД)
if [ -n "$NOWCONTROLLERBOT_TOKEN" ]; then
    open_terminal_tab "NowControllerBot" \
        "cd '$PROJECT_DIR' && set -a; source config/.env; set +a && swift run NowControllerBot"
else
    echo "⚠️  NOWCONTROLLERBOT_TOKEN не установлен, пропускаем NowControllerBot"
fi

# 2. VideoServiceRunner (RoundsvideoBot)
if [ -n "$VIDEO_BOT_TOKEN" ]; then
    open_terminal_tab "VideoServiceRunner (RoundsvideoBot)" \
        "cd '$PROJECT_DIR' && set -a; source config/.env; set +a && LOG_LEVEL=debug swift run VideoServiceRunner"
else
    echo "⚠️  VIDEO_BOT_TOKEN не установлен, пропускаем VideoServiceRunner"
fi

# 3. NowmttBot
if [ -n "$NOWMTTBOT_TOKEN" ]; then
    open_terminal_tab "NowmttBot" \
        "cd '$PROJECT_DIR' && set -a; source config/.env; set +a && swift run NowmttBot"
else
    echo "⚠️  NOWMTTBOT_TOKEN не установлен, пропускаем NowmttBot"
fi

# 4. GSForTextBot
if [ -n "$GSFORTEXTBOT_TOKEN" ]; then
    open_terminal_tab "GSForTextBot" \
        "cd '$PROJECT_DIR' && set -a; source config/.env; set +a && swift run GSForTextBot"
else
    echo "⚠️  GSFORTEXTBOT_TOKEN не установлен, пропускаем GSForTextBot"
fi

# 5. ContentFabrikaBot
if [ -n "$CONTENTFABRIKABOT_TOKEN" ]; then
    open_terminal_tab "ContentFabrikaBot" \
        "cd '$PROJECT_DIR' && set -a; source config/.env; set +a && swift run ContentFabrikaBot"
else
    echo "⚠️  CONTENTFABRIKABOT_TOKEN не установлен, пропускаем ContentFabrikaBot"
fi

# 6. Neurfotobot
if [ -n "$NEURFOTOBOT_TOKEN" ]; then
    open_terminal_tab "Neurfotobot" \
        "cd '$PROJECT_DIR' && set -a; source config/.env; set +a && swift run Neurfotobot"
else
    echo "⚠️  NEURFOTOBOT_TOKEN не установлен, пропускаем Neurfotobot"
fi

# 7. PereskazNowBot
if [ -n "$PERESKAZNOWBOT_TOKEN" ]; then
    open_terminal_tab "PereskazNowBot" \
        "cd '$PROJECT_DIR' && set -a; source config/.env; set +a && swift run PereskazNowBot"
else
    echo "⚠️  PERESKAZNOWBOT_TOKEN не установлен, пропускаем PereskazNowBot"
fi

echo ""
echo "✅ Все сервисы запущены в отдельных вкладках!"
echo "💡 Закрой вкладки (Cmd + W) для остановки соответствующих сервисов"

