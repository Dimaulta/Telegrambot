# Используем базовый образ Node.js
FROM node:20-slim

# Устанавливаем системные зависимости для Playwright
RUN apt-get update && apt-get install -y \
    libnss3 \
    libnspr4 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libdbus-1-3 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libasound2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Копируем package.json и устанавливаем зависимости
COPY package.json ./
RUN npm install

# Устанавливаем Playwright браузеры (только Chromium для экономии места)
RUN npx playwright install chromium --with-deps

# Копируем код приложения
COPY index.js ./

# Создаём папку для persistent профиля
RUN mkdir -p /app/browser-profile

# Открываем порт
EXPOSE 3000

# Запускаем сервис
CMD ["npm", "start"]

