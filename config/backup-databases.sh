#!/bin/bash

# Скрипт для создания бекапов баз данных
# Использование: ./config/backup-databases.sh

set -e  # Остановить выполнение при ошибке

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Путь к директории с бекапами
BACKUP_DIR="/root/Telegrambot/backups"
PROJECT_DIR="/root/Telegrambot"

# Создаём директорию для бекапов, если её нет
mkdir -p "$BACKUP_DIR"

# Формат даты и времени для имени файла: YYYY-MM-DD_HH-MM-SS
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

echo -e "${GREEN}🗄️  Начинаю создание бекапов баз данных...${NC}"
echo "📅 Дата и время: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Функция для создания бекапа
create_backup() {
    local db_path=$1
    local backup_name=$2
    
    if [ ! -f "$db_path" ]; then
        echo -e "${YELLOW}⚠️  База данных не найдена: $db_path${NC}"
        return 1
    fi
    
    local backup_file="${BACKUP_DIR}/${backup_name}_${TIMESTAMP}.sqlite.backup"
    
    # Копируем БД
    cp "$db_path" "$backup_file"
    
    if [ $? -eq 0 ]; then
        local size=$(du -h "$backup_file" | cut -f1)
        echo -e "${GREEN}✅ Бекап создан: ${backup_name}${NC} (${size})"
        echo "   📁 Путь: $backup_file"
        return 0
    else
        echo -e "${RED}❌ Ошибка при создании бекапа: ${backup_name}${NC}"
        return 1
    fi
}

# 1. Бекап общей БД монетизации
echo "📦 Создаю бекап monetization.sqlite..."
create_backup "${PROJECT_DIR}/config/monetization.sqlite" "monetization"

# 2. Бекап БД ContentFabrikaBot
echo "📦 Создаю бекап contentfabrikabot/db.sqlite..."
create_backup "${PROJECT_DIR}/contentfabrikabot/db.sqlite" "contentfabrikabot_db"

echo ""
echo -e "${GREEN}✨ Бекапы успешно созданы!${NC}"

# Очистка старых бекапов (оставляем последние 30 дней)
echo ""
echo "🧹 Проверяю старые бекапы..."
OLD_BACKUPS=$(find "$BACKUP_DIR" -name "*.sqlite.backup" -mtime +30 | wc -l)

if [ "$OLD_BACKUPS" -gt 0 ]; then
    echo "🗑️  Найдено бекапов старше 30 дней: $OLD_BACKUPS"
    find "$BACKUP_DIR" -name "*.sqlite.backup" -mtime +30 -delete
    echo -e "${GREEN}✅ Старые бекапы удалены${NC}"
else
    echo "✅ Старых бекапов не найдено"
fi

# Показываем статистику
echo ""
echo "📊 Статистика бекапов:"
TOTAL_BACKUPS=$(find "$BACKUP_DIR" -name "*.sqlite.backup" | wc -l)
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
echo "   Всего бекапов: $TOTAL_BACKUPS"
echo "   Общий размер: $TOTAL_SIZE"

exit 0
