#!/bin/bash

# Скрипт деплоя Telegram Bot Services на production сервер
# Использование: ./config/deploy.sh

set -e  # Остановить выполнение при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 Начинаю деплой Telegram Bot Services...${NC}"

# Проверка наличия Docker и Docker Compose
if ! command -v docker &> /dev/null; then
    echo -e "${RED}❌ Docker не установлен!${NC}"
    exit 1
fi

if ! command -v docker compose &> /dev/null && ! command -v docker-compose &> /dev/null; then
    echo -e "${RED}❌ Docker Compose не установлен!${NC}"
    exit 1
fi

# Проверка наличия .env файла
if [ ! -f "config/.env" ]; then
    echo -e "${RED}❌ Файл config/.env не найден!${NC}"
    echo -e "${YELLOW}💡 Создай config/.env на основе docs/env.example${NC}"
    echo -e "${YELLOW}💡 Инструкции по безопасной передаче .env см. в docs/DEPLOY.md${NC}"
    exit 1
fi

# Создание необходимых директорий
echo -e "${GREEN}📁 Создаю необходимые директории...${NC}"
mkdir -p Roundsvideobot/Resources/temporaryvideoFiles
mkdir -p Neurfotobot/tmp
mkdir -p config/certs
mkdir -p config/nginx/certs

# Проверка конфигурации nginx
if [ ! -f "config/nginx.conf" ]; then
    echo -e "${YELLOW}⚠️  Файл config/nginx.conf не найден!${NC}"
    echo -e "${YELLOW}💡 Создаю базовую конфигурацию nginx из примера...${NC}"
    if [ -f "docs/nginx.conf.example" ]; then
        cp docs/nginx.conf.example config/nginx.conf
    else
        echo -e "${RED}❌ Файл docs/nginx.conf.example не найден!${NC}"
        exit 1
    fi
fi

# Остановка существующих контейнеров (если есть)
echo -e "${GREEN}🛑 Останавливаю существующие контейнеры...${NC}"
docker compose -f docker-compose.prod.yml down 2>/dev/null || true

# Сборка образов
echo -e "${GREEN}🔨 Собираю Docker образы...${NC}"
docker compose -f docker-compose.prod.yml build --no-cache

# Запуск сервисов
echo -e "${GREEN}🚀 Запускаю сервисы...${NC}"
docker compose -f docker-compose.prod.yml up -d

# Ожидание запуска сервисов
echo -e "${GREEN}⏳ Ожидаю запуска сервисов (30 секунд)...${NC}"
sleep 30

# Проверка статуса контейнеров
echo -e "${GREEN}📊 Проверяю статус контейнеров...${NC}"
docker compose -f docker-compose.prod.yml ps

# Вывод логов последних 20 строк
echo -e "${GREEN}📋 Последние логи сервисов:${NC}"
docker compose -f docker-compose.prod.yml logs --tail=20

echo -e "${GREEN}✅ Деплой завершен!${NC}"
echo -e "${YELLOW}💡 Полезные команды:${NC}"
echo -e "   Просмотр логов: ${GREEN}docker compose -f docker-compose.prod.yml logs -f${NC}"
echo -e "   Статус сервисов: ${GREEN}docker compose -f docker-compose.prod.yml ps${NC}"
echo -e "   Остановка: ${GREEN}docker compose -f docker-compose.prod.yml down${NC}"
echo -e "   Перезапуск: ${GREEN}docker compose -f docker-compose.prod.yml restart${NC}"
