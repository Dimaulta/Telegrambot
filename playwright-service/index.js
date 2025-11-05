const express = require('express');
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

// Папка для persistent профиля браузера
const USER_DATA_DIR = path.join(__dirname, 'browser-profile');

// Создаём папку для профиля если её нет
if (!fs.existsSync(USER_DATA_DIR)) {
  fs.mkdirSync(USER_DATA_DIR, { recursive: true });
}

let browser = null;
let context = null;

// Инициализация браузера
async function initBrowser() {
  console.log('🚀 Инициализация браузера...');
  
  // Запускаем браузер с persistent профилем (куки сохраняются)
  browser = await chromium.launchPersistentContext(USER_DATA_DIR, {
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-blink-features=AutomationControlled',
      '--disable-features=IsolateOrigins,site-per-process',
      '--disable-web-security',
      '--disable-features=VizDisplayCompositor',
      '--window-size=1920,1080',
    ],
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    viewport: { width: 1920, height: 1080 },
    locale: 'en-US',
    timezoneId: 'America/Los_Angeles',
    // Дополнительные параметры для обхода Cloudflare
    permissions: ['geolocation'],
    geolocation: { longitude: -122.4194, latitude: 37.7749 }, // San Francisco
  });

  // Используем тот же контекст (он уже persistent)
  context = browser;

  // Блокируем загрузку медиа-ресурсов
  await context.route('**/*', (route) => {
    const resourceType = route.request().resourceType();
    const allowedTypes = ['document', 'script', 'xhr', 'fetch'];
    if (!allowedTypes.includes(resourceType)) {
      route.abort();
    } else {
      route.continue();
    }
  });

  console.log('✅ Браузер инициализирован');
}

// Инициализация при старте
initBrowser().catch(console.error);

// API endpoint для получения HTML страницы
app.post('/fetch', async (req, res) => {
  const { url } = req.body;

  if (!url) {
    return res.status(400).json({ error: 'URL is required' });
  }

  console.log(`📥 Запрос на получение: ${url}`);

  try {
    // Проверяем, что браузер инициализирован
    if (!context) {
      await initBrowser();
    }

    // Создаём новую страницу
    const page = await context.newPage();

    // Добавляем дополнительные заголовки для обхода Cloudflare
    await page.setExtraHTTPHeaders({
      'Accept-Language': 'en-US,en;q=0.9',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
      'Accept-Encoding': 'gzip, deflate, br',
      'Connection': 'keep-alive',
      'Upgrade-Insecure-Requests': '1',
      'Sec-Fetch-Dest': 'document',
      'Sec-Fetch-Mode': 'navigate',
      'Sec-Fetch-Site': 'none',
      'Cache-Control': 'max-age=0',
    });

    // Убираем признаки автоматизации
    await page.addInitScript(() => {
      Object.defineProperty(navigator, 'webdriver', {
        get: () => undefined,
      });
      
      // Переопределяем plugins
      Object.defineProperty(navigator, 'plugins', {
        get: () => [1, 2, 3, 4, 5],
      });
      
      // Переопределяем languages
      Object.defineProperty(navigator, 'languages', {
        get: () => ['en-US', 'en'],
      });
    });

    try {
      // Переходим на страницу с более мягким ожиданием
      console.log('🌐 Переход на страницу...');
      await page.goto(url, {
        waitUntil: 'domcontentloaded', // Сначала ждём загрузки DOM
        timeout: 60000,
      });

      console.log('⏳ DOM загружен, ждём выполнения JavaScript...');
      
      // Ждём загрузки __NEXT_DATA__ через селектор (более надёжно)
      let hasNextData = false;
      try {
        await page.waitForSelector('script#__NEXT_DATA__', { timeout: 45000 });
        console.log('✅ __NEXT_DATA__ найден через селектор');
        hasNextData = true;
      } catch (e) {
        console.log('⚠️ Селектор не сработал, пробуем через JavaScript...');
        
        // Пробуем ждать через JavaScript (проверяем window.__NEXT_DATA__)
        try {
          await page.waitForFunction(
            () => {
              const script = document.getElementById('__NEXT_DATA__');
              return script && script.textContent && script.textContent.includes('props');
            },
            { timeout: 45000 }
          );
          console.log('✅ __NEXT_DATA__ найден через JavaScript');
          hasNextData = true;
        } catch (e2) {
          console.log('⚠️ __NEXT_DATA__ не загрузился за 45 секунд, ждём ещё 10 секунд...');
          // Ждём ещё 10 секунд - возможно, JS ещё выполняется
          await page.waitForTimeout(10000);
          
          // Последняя попытка проверить
          const checkScript = await page.evaluate(() => {
            const script = document.getElementById('__NEXT_DATA__');
            return script && script.textContent && script.textContent.length > 1000;
          });
          if (checkScript) {
            console.log('✅ __NEXT_DATA__ найден после дополнительного ожидания');
            hasNextData = true;
          } else {
            console.log('❌ __NEXT_DATA__ так и не загрузился');
          }
        }
      }

      // Проверяем, не блокирует ли Cloudflare
      const pageTitle = await page.title();
      const pageUrl = page.url();
      console.log(`📄 Заголовок страницы: "${pageTitle}"`);
      console.log(`🔗 Финальный URL: ${pageUrl}`);
      
      const isCloudflareChallenge = pageTitle.includes('Just a moment') || 
                                    pageTitle.includes('Checking') || 
                                    pageTitle.includes('Attention Required') ||
                                    pageUrl.includes('challenges.cloudflare.com') ||
                                    pageUrl.includes('cf-browser-verification');
      
      if (isCloudflareChallenge) {
        console.log('⚠️ Обнаружен Cloudflare challenge! Пытаемся обойти...');
        
        // Ждём появления кнопки или автоматического прохождения
        try {
          // Пробуем найти и нажать кнопку "Verify" или "Continue"
          const verifyButton = await page.waitForSelector('input[type="button"][value*="Verify"], input[type="button"][value*="Continue"], button:has-text("Verify"), button:has-text("Continue")', { timeout: 10000 }).catch(() => null);
          if (verifyButton) {
            console.log('🖱️ Нажимаем кнопку Verify...');
            await verifyButton.click();
            await page.waitForTimeout(5000);
          }
        } catch (e) {
          console.log('ℹ️ Кнопка не найдена, ждём автоматического прохождения...');
        }
        
        // Ждём прохождения challenge (до 30 секунд)
        console.log('⏳ Ждём прохождения Cloudflare challenge (до 30 секунд)...');
        let challengePassed = false;
        for (let i = 0; i < 6; i++) {
          await page.waitForTimeout(5000);
          
          // Проверяем, изменился ли заголовок
          const newTitle = await page.title();
          const newUrl = page.url();
          
          if (!newTitle.includes('Just a moment') && 
              !newTitle.includes('Checking') && 
              !newTitle.includes('Attention Required') &&
              !newUrl.includes('challenges.cloudflare.com')) {
            console.log('✅ Cloudflare challenge пройден! Заголовок изменился.');
            challengePassed = true;
            break;
          }
          
          // Проверяем наличие __NEXT_DATA__
          const scriptCheck = await page.evaluate(() => {
            const script = document.getElementById('__NEXT_DATA__');
            return script && script.textContent && script.textContent.length > 1000;
          });
          if (scriptCheck) {
            console.log('✅ __NEXT_DATA__ найден после Cloudflare challenge');
            hasNextData = true;
            challengePassed = true;
            break;
          }
        }
        
        if (!challengePassed) {
          console.warn('⚠️ Cloudflare challenge не пройден за 30 секунд, продолжаем с текущим HTML...');
        }
      }

      // Получаем HTML
      const html = await page.content();

      // Проверяем наличие __NEXT_DATA__ в HTML (если ещё не проверили)
      if (!hasNextData) {
        hasNextData = html.includes('__NEXT_DATA__') || 
                     html.includes('__next_data__') ||
                     html.includes('__NEXT_DATA');
      }

      console.log(`✅ HTML получен (${html.length} символов), __NEXT_DATA__: ${hasNextData}`);
      
      if (html.length < 10000) {
        console.warn('⚠️ HTML слишком короткий! Возможно, страница не загрузилась полностью или заблокирована Cloudflare');
        console.log(`📄 Первые 500 символов HTML: ${html.substring(0, 500)}`);
      }

      // Закрываем страницу
      await page.close();

      res.json({
        success: true,
        html: html,
        hasNextData: hasNextData,
        length: html.length
      });

    } catch (error) {
      await page.close();
      throw error;
    }

  } catch (error) {
    console.error('❌ Ошибка при получении страницы:', error.message);
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

// Health check
app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    browser: context ? 'initialized' : 'not initialized'
  });
});

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('🛑 Получен SIGTERM, закрываем браузер...');
  if (context) {
    await context.close();
  }
  process.exit(0);
});

process.on('SIGINT', async () => {
  console.log('🛑 Получен SIGINT, закрываем браузер...');
  if (context) {
    await context.close();
  }
  process.exit(0);
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`🚀 Playwright сервис запущен на порту ${PORT}`);
});

