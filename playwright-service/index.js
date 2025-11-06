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

  // НЕ блокируем медиа-ресурсы - они нужны для перехвата network requests к videos.openai.com
  // Оставляем только блокировку рекламы и трекеров для ускорения
  await context.route('**/*', (route) => {
    const url = route.request().url();
    const resourceType = route.request().resourceType();
    
    // Блокируем только рекламу и трекеры
    if (url.includes('google-analytics') || 
        url.includes('googletagmanager') || 
        url.includes('facebook.com/tr') ||
        url.includes('doubleclick.net') ||
        url.includes('ads.') ||
        resourceType === 'beacon') {
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

  // Инициализируем массив для хранения UUID из перехваченных ответов API
  global.__apiUuids = [];

  try {
    // Проверяем, что браузер инициализирован
    if (!context) {
      await initBrowser();
    }

    // Создаём новую страницу
    const page = await context.newPage();
    
    // Проверяем, есть ли уже куки в persistent профиле
    const existingCookies = await context.cookies();
    const hasCloudflareCookies = existingCookies.some(c => 
      c.name === '__cf_bm' || c.name === 'cf_clearance'
    );
    
    // Устанавливаем куки из SORA_COOKIES только если:
    // 1. Они указаны в переменных окружения
    // 2. И их нет в persistent профиле (или они устарели)
    if (process.env.SORA_COOKIES && !hasCloudflareCookies) {
      try {
        const cookiesStr = process.env.SORA_COOKIES;
        const cookiePairs = cookiesStr.split(';').map(pair => pair.trim());
        const cookies = cookiePairs.map(pair => {
          const [name, ...valueParts] = pair.split('=');
          const value = valueParts.join('='); // На случай, если в значении есть =
          return {
            name: name.trim(),
            value: value.trim(),
            domain: '.sora.chatgpt.com',
            path: '/',
            httpOnly: false,
            secure: true,
            sameSite: 'Lax'
          };
        }).filter(cookie => cookie.name && cookie.value);
        
        if (cookies.length > 0) {
          await context.addCookies(cookies);
          console.log(`🍪 Установлено ${cookies.length} куки из SORA_COOKIES (их не было в persistent профиле)`);
        }
      } catch (e) {
        console.log(`⚠️ Не удалось установить куки: ${e.message}`);
      }
    } else if (hasCloudflareCookies) {
      console.log(`🍪 Используем сохранённые куки из persistent профиля (автоматически обновляются при взаимодействии)`);
    }

    // Перехватываем network requests для поиска ссылок на видео
    // ВАЖНО: устанавливаем перехватчик ДО перехода на страницу!
    const videoUrls = [];
    const allVideoRequests = []; // Для отладки - все запросы к videos.openai.com
    const allRequests = []; // Для диагностики - все запросы
    
    // Перехватываем также requests (не только responses) для полной диагностики
    page.on('request', async (request) => {
      const url = request.url();
      if (url.includes('videos.openai.com') || url.includes('sora.chatgpt.com') || url.includes('openai.com')) {
        console.log(`🔍 Request to: ${url.substring(0, 200)}... [${request.method()}]`);
      }
    });
    
    // Устанавливаем перехватчик response ПЕРЕД переходом на страницу
    page.on('response', async (response) => {
      const url = response.url();
      const status = response.status();
      
      // Логируем ВСЕ запросы к videos.openai.com для отладки
      if (url.includes('videos.openai.com')) {
        console.log(`🎬 Network request to videos.openai.com [${status}]: ${url.substring(0, 300)}...`);
        allVideoRequests.push(url);
        
        // Дополнительное логирование для запросов с /raw
        if (url.includes('/raw') || url.includes('%2Fraw')) {
          console.log(`🔍 RAW REQUEST DETECTED: ${url.substring(0, 400)}...`);
        }
        
        // Декодируем URL для проверки (URL может быть закодирован как %2F вместо /)
        let decodedUrl;
        try {
          decodedUrl = decodeURIComponent(url);
        } catch (e) {
          // Если декодирование не удалось, используем оригинальный URL
          decodedUrl = url;
        }
        
        // Ищем ссылки на videos.openai.com с /az/files/.../raw (оригинальное видео без водяного знака)
        // Проверяем и в оригинальном URL, и в декодированном
        const hasAzFiles = url.includes('/az/files/') || url.includes('%2Faz%2Ffiles%2F') || decodedUrl.includes('/az/files/');
        const hasRaw = url.includes('/raw') || url.includes('%2Fraw') || decodedUrl.includes('/raw');
        
        // Проверяем наличие /drvs/ в декодированном URL (более надёжно)
        const hasDrvs = decodedUrl.includes('/drvs/') || url.includes('%2Fdrvs%2F');
        
        // Детальное логирование для отладки - логируем ВСЕ URL с /az/files/
        if (hasAzFiles && hasRaw) {
          console.log(`🔍 Found /az/files/.../raw URL - Checking: hasDrvs=${hasDrvs}`);
          console.log(`   Original URL: ${url.substring(0, 250)}...`);
          console.log(`   Decoded URL: ${decodedUrl.substring(0, 250)}...`);
        }
        
        if (hasAzFiles && hasRaw) {
          // Декодируем URL полностью для использования
          let finalUrl = decodedUrl;
          // Если декодирование не сработало, пробуем вручную заменить %2F на /
          if (!finalUrl.includes('/az/files/')) {
            finalUrl = url.replace(/%2F/g, '/').replace(/%3A/g, ':').replace(/%3F/g, '?').replace(/%3D/g, '=').replace(/%26/g, '&');
          }

          if (!hasDrvs) {
            console.log(`✅ Found /az/files/.../raw URL in network request (no /drvs/) - БЕЗ ВАТЕРМАРКИ: ${finalUrl.substring(0, 250)}...`);
            videoUrls.push(finalUrl);
          } else {
            console.log(`⚠️ Found /az/files/.../raw but has /drvs/ (watermarked) - SKIPPING: ${finalUrl.substring(0, 250)}...`);
            // НЕ добавляем URL с /drvs/ - это видео с ватермаркой!
          }
        }
      }
      
      // Для диагностики - логируем все запросы к sora.chatgpt.com и openai.com
      if (url.includes('sora.chatgpt.com') || url.includes('openai.com')) {
        allRequests.push({ url, status, type: response.request().resourceType() });
      }
      
      // Перехватываем все API запросы для анализа
      if (url.includes('/api/') || url.includes('/backend/')) {
        console.log(`🔍 API request: ${response.request().method()} ${url} [${status}]`);
        
        // ГИПОТЕЗА: Перехватываем ответы API и извлекаем данные
        if (status === 200) {
          try {
            const responseBody = await response.text();
            if (responseBody && responseBody.length > 0) {
              try {
                const jsonData = JSON.parse(responseBody);
                console.log(`📦 Получен ответ от API ${url}: ${JSON.stringify(jsonData).substring(0, 500)}...`);
                
                // Ищем UUID в ответе
                const findUuid = (obj) => {
                  if (typeof obj === 'string' && /^00000000-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(obj)) {
                    return obj;
                  }
                  if (typeof obj === 'object' && obj !== null) {
                    for (const key in obj) {
                      const found = findUuid(obj[key]);
                      if (found) return found;
                    }
                  }
                  return null;
                };
                
                const uuid = findUuid(jsonData);
                if (uuid) {
                  console.log(`🎯 Найден UUID в ответе API ${url}: ${uuid}`);
                  // Сохраняем в глобальную переменную для использования позже
                  if (!global.__apiUuids) global.__apiUuids = [];
                  global.__apiUuids.push(uuid);
                }
              } catch (e) {
                // Не JSON, пропускаем
              }
            }
          } catch (e) {
            // Ошибка при чтении ответа
          }
        }
      }
    });

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
      // Переходим на страницу - пробуем networkidle для полной загрузки
      console.log('🌐 Переход на страницу...');
      try {
        await page.goto(url, {
          waitUntil: 'networkidle', // Ждём полной загрузки сети (включая JS)
          timeout: 30000,
        });
        console.log('✅ Страница загружена (networkidle)');
      } catch (e) {
        console.log(`⚠️ networkidle timeout, пробуем domcontentloaded: ${e.message}`);
        // Fallback на domcontentloaded если networkidle не сработал
        await page.goto(url, {
          waitUntil: 'domcontentloaded',
          timeout: 30000,
        });
      }

      console.log('⏳ DOM загружен, ждём выполнения JavaScript...');
      
      // БЫСТРЫЙ ПОДХОД: ждём только 2 секунды для network requests (как nosorawm.app)
      console.log('⏳ Ждём 2 секунды для загрузки network requests (быстрый режим)...');
      await page.waitForTimeout(2000);
      
      // Быстрая проверка __NEXT_DATA__
      let hasNextData = false;
      const checkNextData = await page.evaluate(() => {
        const script = document.getElementById('__NEXT_DATA__');
        if (script && script.textContent && script.textContent.length > 1000) {
          return true;
        }
        if (window.__NEXT_DATA__) {
          return true;
        }
        return false;
      });
      
      if (checkNextData) {
        console.log('✅ __NEXT_DATA__ найден!');
        hasNextData = true;
      } else {
        console.log('⚠️ __NEXT_DATA__ не найден, продолжаем с network requests...');
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
        
        // Ждём прохождения challenge (быстро - до 5 секунд)
        console.log('⏳ Ждём прохождения Cloudflare challenge (до 5 секунд)...');
        let challengePassed = false;
        await page.waitForTimeout(5000);
        
        // Проверяем, изменился ли заголовок
        const newTitle = await page.title();
        const newUrl = page.url();
        
        if (!newTitle.includes('Just a moment') && 
            !newTitle.includes('Checking') && 
            !newTitle.includes('Attention Required') &&
            !newUrl.includes('challenges.cloudflare.com')) {
          console.log('✅ Cloudflare challenge пройден!');
          challengePassed = true;
        } else {
          console.warn('⚠️ Cloudflare challenge не пройден за 5 секунд, продолжаем...');
        }
      }

      // Быстрая интеракция: скроллим и кликаем для загрузки данных
      console.log('🖱️ Делаем быструю интеракцию...');
      try {
        // Скроллим страницу быстро
        await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
        await page.waitForTimeout(200);
        await page.evaluate(() => window.scrollTo(0, 0));
        await page.waitForTimeout(200);
        
        // Пробуем кликнуть на видео элемент
        const videoElement = await page.$('video').catch(() => null);
        if (videoElement) {
          await videoElement.click().catch(() => {});
          await page.waitForTimeout(200);
        }
        
      } catch (e) {
        console.log(`⚠️ Интеракция не удалась: ${e.message}`);
      }
      
      // Проверяем __NEXT_DATA__ после интеракции
      if (!hasNextData) {
        const checkAfterInteraction = await page.evaluate(() => {
          const script = document.getElementById('__NEXT_DATA__');
          if (script && script.textContent && script.textContent.length > 1000) {
            return true;
          }
          if (window.__NEXT_DATA__) {
            return true;
          }
          return false;
        });
        if (checkAfterInteraction) {
          console.log('✅ __NEXT_DATA__ найден после интеракции!');
          hasNextData = true;
        }
      }
      
      // Не ждём - уже достаточно времени прошло
      
      // Пробуем сделать запрос к API endpoint с аутентификацией
      // Получаем куки из браузера для использования в API запросах
      let apiUuid = null;
      console.log('🔍 Пробуем получить данные через API endpoint с аутентификацией...');
      try {
        // Получаем все куки из браузера
        const cookies = await page.context().cookies();
        console.log(`🍪 Получено ${cookies.length} куков из браузера`);
        if (cookies.length > 0) {
          console.log(`🍪 Примеры куков: ${cookies.slice(0, 3).map(c => c.name).join(', ')}`);
        }
        
        // Формируем строку с куками для заголовка Cookie
        let cookieString = cookies.map(c => `${c.name}=${c.value}`).join('; ');
        
        // Добавляем токен сессии из переменной окружения, если он есть
        const soraSessionToken = process.env.SORA_SESSION_TOKEN;
        if (soraSessionToken) {
          console.log(`🔑 Используем токен сессии из переменной окружения`);
          // Токен может быть уже с именем куки или только значением
          if (soraSessionToken.startsWith('__Secure-next-auth.session-token=')) {
            // Уже с именем куки
            cookieString = cookieString ? `${cookieString}; ${soraSessionToken}` : soraSessionToken;
          } else {
            // Только значение, добавляем имя куки
            cookieString = cookieString ? `${cookieString}; __Secure-next-auth.session-token=${soraSessionToken}` : `__Secure-next-auth.session-token=${soraSessionToken}`;
          }
        }
        
        // Пробуем получить токены из localStorage/sessionStorage
        const tokens = await page.evaluate(() => {
          const result = {
            localStorage: {},
            sessionStorage: {},
            accessToken: null,
            authToken: null
          };
          
          try {
            // Ищем токены в localStorage
            for (let i = 0; i < localStorage.length; i++) {
              const key = localStorage.key(i);
              const value = localStorage.getItem(key);
              if (key && (key.includes('token') || key.includes('auth') || key.includes('access'))) {
                result.localStorage[key] = value;
                if (key.includes('access') || key.includes('token')) {
                  result.accessToken = value;
                }
              }
            }
            
            // Ищем токены в sessionStorage
            for (let i = 0; i < sessionStorage.length; i++) {
              const key = sessionStorage.key(i);
              const value = sessionStorage.getItem(key);
              if (key && (key.includes('token') || key.includes('auth') || key.includes('access'))) {
                result.sessionStorage[key] = value;
                if (key.includes('access') || key.includes('token')) {
                  result.authToken = value;
                }
              }
            }
          } catch (e) {
            // localStorage/sessionStorage может быть недоступен
          }
          
          return result;
        });
        
        if (tokens.accessToken || tokens.authToken) {
          console.log(`🔑 Найден токен в хранилище: ${tokens.accessToken || tokens.authToken}`);
        }
        
        // Извлекаем ID из URL (например, s_68eaaa225d1c8191909f343ab01bb3fa)
        const urlMatch = url.match(/\/p\/([^\/\?]+)/);
        if (urlMatch) {
          const shareId = urlMatch[1];
          console.log(`🔑 Используем shareId: ${shareId}`);
          
          // Пробуем разные API endpoints с куками (параллельно для скорости)
          const shareIdWithoutPrefix = shareId.startsWith('s_') ? shareId.substring(2) : shareId;
          // Только самые вероятные endpoints (меньше запросов = быстрее)
          const apiEndpoints = [
            `https://sora.chatgpt.com/api/share/${shareId}`,
            `https://sora.chatgpt.com/backend/public/share/${shareId}`,
            `https://sora.chatgpt.com/api/videos/${shareId}`,
            `https://sora.chatgpt.com/backend/public/videos/${shareId}`
          ];
          
          // Делаем запросы параллельно
          console.log(`🔍 Пробуем ${apiEndpoints.length} API endpoints параллельно...`);
          const apiPromises = apiEndpoints.map(apiUrl => 
            page.evaluate(async ({ apiUrl, cookieString, accessToken, authToken }) => {
              try {
                const headers = {
                  'Accept': 'application/json',
                  'Content-Type': 'application/json',
                  'Referer': 'https://sora.chatgpt.com/',
                  'Origin': 'https://sora.chatgpt.com',
                  'Cookie': cookieString,
                  'User-Agent': navigator.userAgent
                };
                
                if (accessToken) {
                  headers['Authorization'] = `Bearer ${accessToken}`;
                } else if (authToken) {
                  headers['Authorization'] = `Bearer ${authToken}`;
                }
                
                const res = await fetch(apiUrl, {
                  method: 'GET',
                  headers: headers,
                  credentials: 'include'
                });
                
                if (res.ok) {
                  const data = await res.json();
                  return { success: true, data, url: apiUrl };
                } else {
                  return { success: false, status: res.status, url: apiUrl };
                }
              } catch (e) {
                return { success: false, error: e.message, url: apiUrl };
              }
            }, { 
              apiUrl, 
              cookieString, 
              accessToken: tokens.accessToken, 
              authToken: tokens.authToken 
            }).catch(err => ({ success: false, error: err.message, url: apiUrl }))
          );
          
          // Ждём результаты всех запросов (с таймаутом 2 секунды - быстро!)
          const apiResults = await Promise.race([
            Promise.all(apiPromises),
            new Promise(resolve => setTimeout(() => resolve([]), 2000))
          ]);
          
          // Ищем UUID в ответах
          const findUuidInResponse = (obj) => {
            if (typeof obj === 'string' && /^00000000-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(obj)) {
              return obj;
            }
            if (typeof obj === 'object' && obj !== null) {
              for (const key in obj) {
                const found = findUuidInResponse(obj[key]);
                if (found) return found;
              }
            }
            return null;
          };
          
          for (const response of apiResults) {
            if (response && response.success && response.data) {
              console.log(`✅ Получены данные от API endpoint: ${response.url}`);
              const foundApiUuid = findUuidInResponse(response.data);
              if (foundApiUuid) {
                apiUuid = foundApiUuid;
                console.log(`🎯 Найден UUID из API: ${apiUuid}`);
                break; // Используем первый найденный
              }
            }
          }
        }
      } catch (e) {
        console.log(`⚠️ API запросы не удались: ${e.message}`);
      }
      
      // БЫСТРЫЙ РЕЖИМ: не ждём видео элементы, сразу получаем HTML и network requests

      // Получаем HTML сначала
      let html = await page.content();
      
      // Пробуем извлечь данные напрямую из JavaScript контекста страницы
      console.log('🔍 Пытаемся извлечь данные из JavaScript контекста страницы...');
      try {
        const pageData = await page.evaluate(() => {
          const result = {
            nextData: null,
            videoUrls: [],
            windowData: {}
          };
          
          // Пробуем получить __NEXT_DATA__ из скрипта
          const nextDataScript = document.getElementById('__NEXT_DATA__');
          if (nextDataScript && nextDataScript.textContent) {
            try {
              result.nextData = JSON.parse(nextDataScript.textContent);
            } catch (e) {
              result.nextData = nextDataScript.textContent;
            }
          }
          
          // Пробуем получить данные из window объекта
          if (window.__NEXT_DATA__) {
            result.windowData.nextData = window.__NEXT_DATA__;
          }
          
          // ГИПОТЕЗА 1: Ищем данные в window объекте (может быть, там есть данные о видео)
          if (window.__NEXT_DATA__) {
            try {
              const nextData = window.__NEXT_DATA__;
              result.windowData.nextDataString = JSON.stringify(nextData).substring(0, 1000);
            } catch (e) {}
          }
          
          // ГИПОТЕЗА 2: Ищем JSON-LD (структурированные данные)
          const jsonLdScripts = Array.from(document.querySelectorAll('script[type="application/ld+json"]'));
          jsonLdScripts.forEach(script => {
            try {
              const data = JSON.parse(script.textContent);
              if (JSON.stringify(data).includes('videos.openai.com')) {
                result.windowData.jsonLd = data;
              }
            } catch (e) {}
          });
          
          // ГИПОТЕЗА 3: Ищем данные в мета-тегах
          const metaTags = Array.from(document.querySelectorAll('meta[property], meta[name]'));
          metaTags.forEach(meta => {
            const content = meta.getAttribute('content');
            if (content && content.includes('videos.openai.com')) {
              result.windowData.metaTags = result.windowData.metaTags || [];
              result.windowData.metaTags.push({
                property: meta.getAttribute('property') || meta.getAttribute('name'),
                content: content
              });
            }
          });
          
          // ГИПОТЕЗА 4: Ищем данные в window объекте (может быть, там есть данные о видео)
          const windowKeys = Object.keys(window).filter(key => 
            key.includes('video') || key.includes('sora') || key.includes('data')
          );
          if (windowKeys.length > 0) {
            result.windowData.windowKeys = windowKeys;
          }
          
          // Ищем все ссылки на видео в DOM
          const allLinks = Array.from(document.querySelectorAll('a[href*="videos.openai.com"], source[src*="videos.openai.com"], video[src*="videos.openai.com"]'));
          allLinks.forEach(link => {
            const url = link.href || link.src;
            if (url && url.includes('videos.openai.com') && url.includes('/az/files/') && url.includes('/raw')) {
              result.videoUrls.push(url);
            }
          });
          
          // Ищем в data-атрибутах
          const elementsWithData = Array.from(document.querySelectorAll('[data-video], [data-url], [data-src]'));
          elementsWithData.forEach(el => {
            const dataUrl = el.getAttribute('data-video') || el.getAttribute('data-url') || el.getAttribute('data-src');
            if (dataUrl && dataUrl.includes('videos.openai.com') && dataUrl.includes('/az/files/') && dataUrl.includes('/raw')) {
              result.videoUrls.push(dataUrl);
            }
          });
          
          return result;
        });
        
        if (pageData.nextData || pageData.windowData.nextData) {
          const nextData = pageData.nextData || pageData.windowData.nextData;
          console.log('✅ Найдены данные в __NEXT_DATA__ через JavaScript!');
          hasNextData = true;
          // Добавляем __NEXT_DATA__ в HTML если его там нет
          if (!html.includes('__NEXT_DATA__')) {
            const nextDataScript = `<script id="__NEXT_DATA__" type="application/json">${typeof nextData === 'string' ? nextData : JSON.stringify(nextData)}</script>`;
            html = nextDataScript + html;
            console.log('✅ Добавили __NEXT_DATA__ в HTML из JavaScript контекста');
          }
        }
        
        if (pageData.videoUrls && pageData.videoUrls.length > 0) {
          console.log(`🎬 Найдено ${pageData.videoUrls.length} ссылок на видео через JavaScript контекст!`);
          pageData.videoUrls.forEach((url, i) => {
            console.log(`   ${i + 1}. ${url.substring(0, 200)}...`);
            if (!videoUrls.includes(url)) {
              videoUrls.push(url);
            }
          });
        }
        
        // Логируем данные из гипотез
        if (pageData.windowData) {
          if (pageData.windowData.jsonLd) {
            console.log(`📦 Найдены JSON-LD данные: ${JSON.stringify(pageData.windowData.jsonLd).substring(0, 300)}...`);
          }
          if (pageData.windowData.metaTags && pageData.windowData.metaTags.length > 0) {
            console.log(`📋 Найдено ${pageData.windowData.metaTags.length} мета-тегов с видео URL`);
            pageData.windowData.metaTags.forEach((meta, i) => {
              console.log(`   ${i + 1}. ${meta.property}: ${meta.content.substring(0, 150)}...`);
            });
          }
          if (pageData.windowData.windowKeys && pageData.windowData.windowKeys.length > 0) {
            console.log(`🔑 Найдены ключи в window: ${pageData.windowData.windowKeys.join(', ')}`);
          }
        }
      } catch (e) {
        console.log(`⚠️ Ошибка при извлечении данных из JavaScript: ${e.message}`);
      }

      // Проверяем наличие __NEXT_DATA__ в HTML (если ещё не проверили)
      if (!hasNextData) {
        hasNextData = html.includes('__NEXT_DATA__') || 
                     html.includes('__next_data__') ||
                     html.includes('__NEXT_DATA');
      }

      console.log(`✅ HTML получен (${html.length} символов), __NEXT_DATA__: ${hasNextData}`);
      console.log(`🎬 Всего запросов к videos.openai.com: ${allVideoRequests.length}`);
      console.log(`🎬 Найдено ${videoUrls.length} ссылок /az/files/.../raw в network requests`);
      console.log(`📊 Всего запросов к sora.chatgpt.com/openai.com: ${allRequests.length}`);
      
      if (allVideoRequests.length > 0 && videoUrls.length === 0) {
        console.log(`⚠️ Запросы к videos.openai.com есть, но /az/files/.../raw не найдено! Примеры запросов:`);
        allVideoRequests.slice(0, 5).forEach((req, i) => {
          console.log(`   ${i + 1}. ${req.substring(0, 200)}...`);
        });
      }
      
      if (allVideoRequests.length === 0) {
        console.log(`⚠️ НЕТ запросов к videos.openai.com вообще! Страница не загружает видео напрямую.`);
        console.log(`📊 Примеры других запросов к openai.com/sora.chatgpt.com:`);
        allRequests.slice(0, 10).forEach((req, i) => {
          console.log(`   ${i + 1}. [${req.status}] ${req.type}: ${req.url.substring(0, 150)}...`);
        });
      }
      
      if (html.length < 10000) {
        console.warn('⚠️ HTML слишком короткий! Возможно, страница не загрузилась полностью или заблокирована Cloudflare');
        console.log(`📄 Первые 500 символов HTML: ${html.substring(0, 500)}`);
      }

      // НЕ закрываем страницу здесь - она нужна для API запросов
      // Закроем её позже, после всех API запросов

      // Фильтруем уникальные ссылки на видео (уже отфильтрованы от /drvs/)
      const uniqueVideoUrls = [...new Set(videoUrls)];
      
      console.log(`📊 ИТОГО: Найдено ${videoUrls.length} ссылок в videoUrls (до фильтрации), ${uniqueVideoUrls.length} уникальных`);
      if (uniqueVideoUrls.length > 0) {
        console.log(`📋 Уникальные ссылки на видео (БЕЗ /drvs/):`);
        uniqueVideoUrls.forEach((url, i) => {
          console.log(`   ${i + 1}. ${url.substring(0, 250)}...`);
        });
      } else {
        console.log(`⚠️ НЕ НАЙДЕНО ссылок на видео БЕЗ /drvs/ в network requests!`);
        console.log(`📋 Всего запросов к videos.openai.com: ${allVideoRequests.length}`);
        if (allVideoRequests.length > 0) {
          console.log(`📋 Примеры запросов к videos.openai.com:`);
          allVideoRequests.slice(0, 5).forEach((url, i) => {
            console.log(`   ${i + 1}. ${url.substring(0, 300)}...`);
          });
        }
      }

      // Находим UUID основного видео из /drvs/md/raw или /drvs/thumbnail/raw (версия с ватермаркой)
      // Это нужно, чтобы исключить этот UUID и выбрать другой (версию без ватермарки)
      const mainVideoUuids = new Set();
      allVideoRequests.forEach(url => {
        // Декодируем URL для проверки
        let decodedUrl = url;
        try {
          decodedUrl = decodeURIComponent(url);
        } catch (e) {
          decodedUrl = url.replace(/%2F/g, '/').replace(/%3A/g, ':');
        }
        
        // Ищем /drvs/md/raw - это версия С ватермаркой
        if (decodedUrl.includes('/drvs/md/raw')) {
          const match = decodedUrl.match(/\/az\/files\/[^/]+_([a-f0-9-]+)\/drvs\/md\/raw/);
          if (match) {
            mainVideoUuids.add(match[1]);
            console.log(`🔍 Найден UUID основного видео (С ватермаркой): ${match[1]}`);
          }
        }
        // Также пробуем /drvs/thumbnail/raw для извлечения UUID
        if (decodedUrl.includes('/drvs/thumbnail/raw')) {
          const match = decodedUrl.match(/\/az\/files\/[^/]+_([a-f0-9-]+)\/drvs\/thumbnail\/raw/);
          if (match) {
            mainVideoUuids.add(match[1]);
            console.log(`🔍 Найден UUID основного видео из thumbnail (С ватермаркой): ${match[1]}`);
          }
        }
      });
      
      if (mainVideoUuids.size > 0) {
        console.log(`🎯 UUID основного видео (с ватермаркой): ${Array.from(mainVideoUuids).join(', ')}`);
      } else {
        console.log(`⚠️ UUID основного видео не найден в network requests`);
      }

      // ВАЖНО: videoUrlsWithUuid будет создан ПОСЛЕ добавления новых ссылок из HTML
      // Пока что просто логируем найденные ссылки
      const tempVideoUrls = uniqueVideoUrls.filter(url => url.includes('/az/files/') && url.includes('/raw'));
      console.log(`🎬 Найдено ${tempVideoUrls.length} ссылок /az/files/{uuid}/raw в network requests (БЕЗ /drvs/):`);

      // Пытаемся найти UUID из __NEXT_DATA__ или HTML для проверки соответствия
      let expectedUuid = null;
      
      // Сначала пробуем UUID из API (самый быстрый способ)
      if (apiUuid) {
        expectedUuid = apiUuid;
        console.log(`🎯 Используем UUID из API: ${expectedUuid}`);
      }
      
      // Также проверяем UUID из перехваченных ответов API
      if (global.__apiUuids && global.__apiUuids.length > 0) {
        const interceptedUuid = global.__apiUuids.find(uuid => !mainVideoUuids.has(uuid.toLowerCase()));
        if (interceptedUuid) {
          expectedUuid = interceptedUuid;
          console.log(`🎯 Используем UUID из перехваченных ответов API: ${expectedUuid}`);
        }
      }
      
      // Затем пробуем из __NEXT_DATA__ (если API не дал результат)
      if (hasNextData && html) {
        try {
          const nextDataMatch = html.match(/<script id="__NEXT_DATA__"[^>]*>(.*?)<\/script>/);
          if (nextDataMatch) {
            const nextData = JSON.parse(nextDataMatch[1]);
            console.log(`🔍 Ищем ссылки на видео в __NEXT_DATA__...`);
            
            // Ищем ссылки на видео в __NEXT_DATA__
            const findVideoUrls = (obj, path = '') => {
              const urls = [];
              if (typeof obj === 'string' && obj.includes('videos.openai.com') && obj.includes('/az/files/') && obj.includes('/raw')) {
                urls.push(obj);
                console.log(`🎯 Найдена ссылка на видео в __NEXT_DATA__ (path: ${path}): ${obj.substring(0, 150)}...`);
              }
              if (typeof obj === 'object' && obj !== null) {
                for (const key in obj) {
                  const found = findVideoUrls(obj[key], path ? `${path}.${key}` : key);
                  urls.push(...found);
                }
              }
              return urls;
            };
            
            const foundUrls = findVideoUrls(nextData);
            if (foundUrls.length > 0) {
              console.log(`✅ Найдено ${foundUrls.length} ссылок на видео в __NEXT_DATA__!`);
              for (const url of foundUrls) {
                // Проверяем, что это не ссылка с ватермаркой (не содержит UUID из mainVideoUuids)
                const urlUuid = url.match(/\/az\/files\/([a-f0-9-]+)\/raw/);
                if (urlUuid && !mainVideoUuids.has(urlUuid[1].toLowerCase())) {
                  console.log(`✅ Найдена ссылка БЕЗ ватермарки в __NEXT_DATA__: ${url.substring(0, 150)}...`);
                  if (!videoUrls.includes(url)) {
                    videoUrls.push(url);
                    console.log(`✅ Добавлена ссылка из __NEXT_DATA__ в список`);
                  }
                  if (!expectedUuid) {
                    expectedUuid = urlUuid[1];
                    console.log(`🎯 Используем UUID из ссылки в __NEXT_DATA__: ${expectedUuid}`);
                  }
                }
              }
            }
            
            // Если ссылки не найдены, ищем UUID в структуре данных
            if (!expectedUuid) {
              const findUuid = (obj) => {
                if (typeof obj === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(obj)) {
                  return obj;
                }
                if (typeof obj === 'object' && obj !== null) {
                  for (const key in obj) {
                    const found = findUuid(obj[key]);
                    if (found) return found;
                  }
                }
                return null;
              };
              expectedUuid = findUuid(nextData);
              if (expectedUuid) {
                console.log(`🎯 Найден ожидаемый UUID из __NEXT_DATA__: ${expectedUuid}`);
              }
            }
          }
        } catch (e) {
          console.log(`⚠️ Не удалось извлечь данные из __NEXT_DATA__: ${e.message}`);
        }
      }
      
      // Если __NEXT_DATA__ не загружен, пробуем найти downloadable_url в HTML
      if (!expectedUuid && html) {
        console.log(`🔍 Ищем downloadable_url в HTML (length: ${html.length})...`);
        
        // Ищем downloadable_url в HTML (может быть в разных форматах)
        const downloadablePatterns = [
          /"downloadable_url"\s*:\s*"([^"]+videos\.openai\.com[^"]+)"/gi,
          /downloadable_url["\s:=]+([^\s"<>]+videos\.openai\.com[^\s"<>]+)/gi,
          /downloadableUrl["\s:=]+([^\s"<>]+videos\.openai\.com[^\s"<>]+)/gi,
          /downloadable_url["\s:=]+([^"<>]+)/gi,
          /"downloadable_url":\s*"([^"]+)"/gi
        ];
        
        for (let i = 0; i < downloadablePatterns.length; i++) {
          const pattern = downloadablePatterns[i];
          const matches = Array.from(html.matchAll(pattern));
          console.log(`🔍 Pattern ${i + 1} found ${matches.length} matches`);
          
          for (const match of matches) {
            const downloadableUrl = match[1];
            console.log(`   Checking: ${downloadableUrl.substring(0, 150)}...`);
            if (downloadableUrl && downloadableUrl.includes('/az/files/')) {
              const uuidMatch = downloadableUrl.match(/\/az\/files\/([a-f0-9-]+)/);
              if (uuidMatch) {
                expectedUuid = uuidMatch[1];
                console.log(`🎯 Найден ожидаемый UUID из downloadable_url в HTML: ${expectedUuid}`);
                break;
              }
            }
          }
          if (expectedUuid) break;
        }
        
        // АЛЬТЕРНАТИВНЫЙ ПОДХОД: используем все найденные UUID из HTML
        // Правильный UUID может быть среди них, но не в network requests
        if (!expectedUuid) {
          const allUuids = html.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi);
          if (allUuids) {
            const uniqueUuids = [...new Set(allUuids)];
            console.log(`🔍 Найдено ${uniqueUuids.length} уникальных UUID в HTML: ${uniqueUuids.slice(0, 10).join(', ')}...`);
            
            // Ищем UUID, которые НЕ совпадают с основным видео (версия БЕЗ ватермарки)
            const nonMainUuids = uniqueUuids.filter(uuid => {
              return !mainVideoUuids.has(uuid.toLowerCase());
            });
            
            if (nonMainUuids.length > 0) {
              console.log(`🎯 Найдено ${nonMainUuids.length} UUID, которые НЕ совпадают с основным видео (возможно, это версия БЕЗ ватермарки): ${nonMainUuids.slice(0, 5).join(', ')}`);
              
              // Ищем ссылку на видео с этим UUID в HTML
              for (const uuid of nonMainUuids) {
                // Ищем ссылку с этим UUID в HTML
                const uuidPattern = new RegExp(`https://videos\\.openai\\.com/az/files/${uuid}/raw[^"\\s<>]+`, 'gi');
                const matches = html.match(uuidPattern);
                if (matches && matches.length > 0) {
                  const foundUrl = matches[0];
                  console.log(`✅ Найдена ссылка на видео с UUID ${uuid} в HTML: ${foundUrl.substring(0, 150)}...`);
                  // Добавляем эту ссылку в videoUrls
                  if (!videoUrls.includes(foundUrl)) {
                    videoUrls.push(foundUrl);
                    console.log(`✅ Добавлена ссылка на видео с UUID ${uuid} из HTML в список`);
                  }
                  expectedUuid = uuid;
                  break;
                }
              }
              
              // Если ссылка не найдена в HTML, пробуем использовать API для получения данных по UUID
              if (!expectedUuid) {
                expectedUuid = nonMainUuids[0];
                console.log(`⚠️ Используем UUID из HTML (не совпадает с основным видео): ${expectedUuid} (но ссылка на видео не найдена в HTML - пробуем API)`);
                
                // Пробуем получить данные через API по UUID
                console.log(`🔍 Пробуем получить данные через API для UUID ${expectedUuid}...`);
                try {
                  // Получаем shareId из URL
                  const urlMatch = url.match(/\/p\/([^\/\?]+)/);
                  const shareId = urlMatch ? urlMatch[1] : null;
                  
                  // Получаем куки и токен для API запроса
                  const cookies = await page.context().cookies();
                  const cookieString = cookies.map(c => `${c.name}=${c.value}`).join('; ');
                  const soraSessionToken = process.env.SORA_SESSION_TOKEN;
                  
                  // Пробуем разные API endpoints для получения данных по UUID
                  const apiEndpoints = [
                    `https://sora.chatgpt.com/api/videos/${expectedUuid}`,
                    `https://sora.chatgpt.com/backend/public/videos/${expectedUuid}`,
                    ...(shareId ? [`https://sora.chatgpt.com/api/share/${shareId}`] : [])
                  ];
                  
                  for (const apiUrl of apiEndpoints) {
                    try {
                      console.log(`🔍 Пробуем API endpoint: ${apiUrl}`);
                      const apiResponse = await page.evaluate(async ({ apiUrl, cookieString, sessionToken }) => {
                        try {
                          const headers = {
                            'Accept': 'application/json',
                            'Content-Type': 'application/json',
                            'Referer': 'https://sora.chatgpt.com/',
                            'Origin': 'https://sora.chatgpt.com',
                            'Cookie': cookieString,
                            'User-Agent': navigator.userAgent
                          };
                          
                          if (sessionToken) {
                            headers['Authorization'] = `Bearer ${sessionToken}`;
                          }
                          
                          const res = await fetch(apiUrl, {
                            method: 'GET',
                            headers: headers,
                            credentials: 'include'
                          });
                          
                          if (res.ok) {
                            const data = await res.json();
                            return { success: true, data, url: apiUrl };
                          } else {
                            return { success: false, status: res.status, url: apiUrl };
                          }
                        } catch (e) {
                          return { success: false, error: e.message, url: apiUrl };
                        }
                      }, { 
                        apiUrl, 
                        cookieString, 
                        sessionToken: soraSessionToken 
                      });
                      
                      if (apiResponse && apiResponse.success && apiResponse.data) {
                        console.log(`✅ Получены данные от API: ${apiUrl}`);
                        console.log(`📦 Ответ API (первые 500 символов): ${JSON.stringify(apiResponse.data).substring(0, 500)}...`);
                        
                        // Ищем ссылку на видео в ответе API
                        const findVideoUrl = (obj) => {
                          if (typeof obj === 'string' && obj.includes('videos.openai.com') && obj.includes('/az/files/') && obj.includes('/raw') && !obj.includes('/drvs/')) {
                            return obj;
                          }
                          if (typeof obj === 'object' && obj !== null) {
                            for (const key in obj) {
                              const found = findVideoUrl(obj[key]);
                              if (found) return found;
                            }
                          }
                          return null;
                        };
                        
                        const foundApiUrl = findVideoUrl(apiResponse.data);
                        if (foundApiUrl) {
                          console.log(`🎯 Найдена ссылка на видео в ответе API: ${foundApiUrl.substring(0, 150)}...`);
                          if (!videoUrls.includes(foundApiUrl)) {
                            videoUrls.push(foundApiUrl);
                            console.log(`✅ Добавлена ссылка из API в список`);
                            break; // Используем первую найденную ссылку
                          }
                        }
                      }
                    } catch (e) {
                      console.log(`⚠️ Ошибка при запросе к API ${apiUrl}: ${e.message}`);
                    }
                  }
                } catch (e) {
                  console.log(`⚠️ Ошибка при попытке получить данные через API: ${e.message}`);
                }
              }
            } else {
              console.log(`⚠️ Все UUID в HTML совпадают с основным видео. Правильный UUID не загружен на страницу.`);
            }
          }
        }
      }

      // Пересоздаём videoUrlsWithUuid после добавления новых ссылок из HTML
      const uniqueVideoUrlsFinal = [...new Set(videoUrls)];
      let videoUrlsWithUuid = uniqueVideoUrlsFinal
        .filter(url => url.includes('/az/files/') && url.includes('/raw'))
        .map(url => {
          const match = url.match(/\/az\/files\/([a-f0-9-]+)\/raw/);
          if (!match) return null;
          
          // ВАЖНО: Проверяем наличие /drvs/ в URL - если есть, то это видео С ватермаркой
          // Также проверяем UUID - если начинается с 00000000-, то это тоже видео С ватермаркой
          const hasDrvs = url.includes('/drvs/');
          const uuid = match[1];
          
          // UUID начинающийся с 00000000- обычно означает видео С ватермаркой
          const hasWatermarkUuid = uuid.startsWith('00000000-');
          
          // isMainVideo = true если URL содержит /drvs/ ИЛИ UUID начинается с 00000000-
          const isMainVideo = hasDrvs || hasWatermarkUuid;
          
          return { url, uuid, isMainVideo, hasDrvs };
        })
        .filter(item => item !== null);
      
      console.log(`🎬 После добавления ссылок из HTML: ${videoUrlsWithUuid.length} ссылок /az/files/{uuid}/raw`);
      videoUrlsWithUuid.forEach((item, i) => {
        const source = item.isMainVideo ? '⚠️ MAIN VIDEO' : '⭐ NOT MAIN VIDEO';
        console.log(`   ${i + 1}. ${source} UUID: ${item.uuid}, URL: ${item.url.substring(0, 150)}...`);
      });

      // Приоритизация: 
      // 1. UUID из downloadable_url (если найден) - самый высокий приоритет
      // 2. UUID, который НЕ совпадает с основным видео UUID (версия БЕЗ ватермарки)
      // 3. Все остальные (первый найденный)
      const prioritizedUrls = videoUrlsWithUuid
        .sort((a, b) => {
          // Приоритет 1: ожидаемый UUID из downloadable_url
          if (expectedUuid) {
            if (a.uuid === expectedUuid && b.uuid !== expectedUuid) return -1;
            if (a.uuid !== expectedUuid && b.uuid === expectedUuid) return 1;
          }
          // Приоритет 2: UUID, который НЕ совпадает с основным видео (версия БЕЗ ватермарки)
          if (mainVideoUuids.size > 0) {
            if (!a.isMainVideo && b.isMainVideo) return -1; // a - не основное видео, b - основное, выбираем a
            if (a.isMainVideo && !b.isMainVideo) return 1;  // a - основное видео, b - не основное, выбираем b
          }
          // Сохраняем порядок для остальных
          return 0;
        })
        .map(item => item.url);

      console.log(`🎯 Приоритизированные URL:`);
      prioritizedUrls.forEach((url, i) => {
        const item = videoUrlsWithUuid.find(v => v.url === url);
        const uuid = item?.uuid;
        const isExpected = expectedUuid && uuid === expectedUuid;
        const isMainVideo = item?.isMainVideo || false;
        let status = '❓';
        if (isExpected) status = '✅ EXPECTED';
        else if (!isMainVideo && mainVideoUuids.size > 0) status = '⭐ NOT MAIN VIDEO (should be without watermark)';
        else if (isMainVideo) status = '⚠️ MAIN VIDEO (has watermark)';
        console.log(`   ${i + 1}. ${status} UUID: ${uuid}, URL: ${url.substring(0, 150)}...`);
      });

      // Фильтруем ссылки с ватермаркой, если есть ссылки без ватермарки
      const urlsWithoutWatermark = prioritizedUrls.filter(url => {
        const item = videoUrlsWithUuid.find(v => v.url === url);
        return item && !item.isMainVideo;
      });
      
      // Если есть ссылки без ватермарки, используем только их
      // ВАЖНО: Если все ссылки с ватермаркой, НЕ возвращаем их - лучше вернуть пустой массив
      const finalVideoUrls = urlsWithoutWatermark.length > 0 ? urlsWithoutWatermark : [];
      
      // Проверяем, все ли найденные URL совпадают с основным видео (с ватермаркой)
      const allAreMainVideo = prioritizedUrls.length > 0 && 
                              prioritizedUrls.every(url => {
                                const item = videoUrlsWithUuid.find(v => v.url === url);
                                return item?.isMainVideo === true;
                              });
      
      const warning = allAreMainVideo && !hasNextData 
        ? "⚠️ Все найденные URL совпадают с основным видео (с ватермаркой). Правильный UUID доступен только в __NEXT_DATA__, который не загрузился. Возможно, требуется аутентификация или Cloudflare блокирует загрузку."
        : null;
      
      if (urlsWithoutWatermark.length > 0 && prioritizedUrls.length > urlsWithoutWatermark.length) {
        console.log(`✅ Отфильтрованы ссылки с ватермаркой. Осталось ${urlsWithoutWatermark.length} ссылок БЕЗ ватермарки из ${prioritizedUrls.length}`);
      }
      
      if (allAreMainVideo && finalVideoUrls.length === 0) {
        console.log(`❌ ВСЕ найденные ссылки имеют ватермарку! Не возвращаем их. Нужна правильная ссылка из __NEXT_DATA__ или API.`);
        console.log(`💡 Найден UUID без ватермарки в HTML: ${expectedUuid || 'не найден'}, но ссылка на видео не найдена.`);
      }

      // Закрываем страницу после всех операций
      await page.close();

      res.json({
        success: true,
        html: html,
        hasNextData: hasNextData,
        length: html.length,
        videoUrls: finalVideoUrls, // Приоритизированные ссылки (без /drvs/)
        foundUuids: videoUrlsWithUuid.map(item => ({ uuid: item.uuid, url: item.url, isMainVideo: item.isMainVideo })), // Для отладки
        expectedUuid: expectedUuid || null, // UUID из __NEXT_DATA__ (если найден)
        mainVideoUuids: Array.from(mainVideoUuids), // UUID основного видео (с ватермаркой)
        warning: warning // Предупреждение, если все URL совпадают с основным видео
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

