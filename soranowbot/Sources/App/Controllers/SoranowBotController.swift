import Vapor
import Foundation

final class SoranowBotController {
    func handleWebhook(_ req: Request) async throws -> Response {
        req.logger.info("═══════════════════════════════════════════════")
        req.logger.info("🔔 SoranowBot webhook hit!")
        req.logger.info("Method: \(req.method), Path: \(req.url.path)")
        
        let token = Environment.get("SORANOWBOT_TOKEN")
        guard let token = token, token.isEmpty == false else {
            req.logger.error("SORANOWBOT_TOKEN is missing")
            return Response(status: .internalServerError)
        }

        let rawBody = req.body.string ?? ""
        req.logger.info("📦 Raw body length: \(rawBody.count) characters")
        if rawBody.count > 0 && rawBody.count < 500 {
            req.logger.debug("Raw body: \(rawBody)")
        }

        req.logger.info("🔍 Decoding SoranowBotUpdate...")
        let update = try? req.content.decode(SoranowBotUpdate.self)
        if update == nil { 
            req.logger.error("❌ Failed to decode SoranowBotUpdate - check raw body above")
        return Response(status: .ok)
    }
        req.logger.info("✅ SoranowBotUpdate decoded successfully")

        guard let message = update?.message else {
            req.logger.warning("⚠️ No message in update (update_id: \(update?.update_id ?? -1))")
            return Response(status: .ok)
        }
        let text = message.text ?? ""
        req.logger.info("📨 Incoming message - chatId=\(message.chat.id), text length=\(text.count)")
        if !text.isEmpty {
            req.logger.info("📝 Message text: \(text.prefix(200))")
        }

        req.logger.info("🔍 Checking for Sora URL in message...")
        guard let shareUrl = extractSoraShareURL(from: text) else {
            req.logger.info("ℹ️ No Sora URL found in message (text: \(text.prefix(100)))")
            return Response(status: .ok)
        }
        req.logger.info("Detected Sora share URL: \(shareUrl)")

        // ВАЖНО: Telegram webhook должен быстро ответить (в течение 60 секунд)
        // Отправляем ответ сразу, обработку делаем в фоне
        // Сохраняем необходимые данные для фоновой задачи
        let chatId = message.chat.id
        let client = req.client
        let logger = req.logger
        
        Task { [token, shareUrl, chatId] in
            logger.info("🚀 Background task started for URL: \(shareUrl)")
            do {
                // Отправляем уведомление о начале обработки
                logger.info("📤 Sending 'processing' message to user...")
                _ = try? await sendTelegramMessage(token: token, chatId: chatId, text: "⏳ Обрабатываю ссылку, подожди немного...", client: client)
                logger.info("✅ 'Processing' message sent")
                
                // Создаём новый Request для фоновой обработки (используем eventLoop из оригинального req)
                logger.info("🔧 Creating background request...")
                let backgroundReq = Request(application: req.application, method: .GET, url: URI(string: "/"), on: req.eventLoop)
                logger.info("✅ Background request created, calling fetchDirectSoraVideoUrl...")
                
                let directUrl = try await fetchDirectSoraVideoUrl(from: shareUrl, req: backgroundReq)
                logger.info("✅ fetchDirectSoraVideoUrl completed, extracted URL length=\(directUrl.count), URL: \(directUrl.prefix(200))...")
                
                // Проверяем, что это действительно ссылка на видео, а не исходная ссылка на Sora
                guard directUrl.contains("videos.openai.com") else {
                    logger.error("Extracted URL is not a video URL: \(directUrl)")
                    _ = try? await sendTelegramMessage(token: token, chatId: chatId, text: "Не удалось извлечь прямую ссылку на видео. Попробуй ещё раз, мой хороший 💕", client: client)
                    return
                }
                
                // ВАЖНО: /az/files/{uuid}/raw ссылки - это эталонные ссылки от nosorawm.app!
                // Они могут возвращать 403 при прямой проверке (SAS токены специфичны для пути),
                // но для Telegram API могут работать. Поэтому НЕ проверяем их, а сразу отправляем!
                if directUrl.contains("/az/files/") && directUrl.contains("/raw") && !directUrl.contains("/drvs/") {
                    logger.info("✅ Found /az/files/{uuid}/raw URL (like nosorawm.app format) - sending directly without test (may work for Telegram API even if direct test fails)")
                    // Пропускаем проверку и fallback - отправляем напрямую!
                }
                
                logger.info("📤 Sending final URL to Telegram: \(directUrl.prefix(200))...")
                let sent = try await sendTelegramMessage(token: token, chatId: chatId, text: directUrl, client: client)
                if sent {
                    logger.info("✅ Successfully sent URL to Telegram")
                } else {
                    logger.error("❌ Failed to send URL to Telegram")
                }
            } catch {
                logger.error("Failed to extract/send direct URL: \(String(describing: error))")
                let errorMsg = error.localizedDescription
                let userMsg: String
                if errorMsg.contains("Cloudflare") {
                    userMsg = "Cloudflare блокирует запрос. Попробуй:\n1) Включить VPN на США\n2) Обновить куки в config/.env\n3) Попробовать позже"
                } else {
                    userMsg = "Не удалось извлечь прямую ссылку. Попробуй ещё раз, мой хороший 💕"
                }
                _ = try? await sendTelegramMessage(token: token, chatId: chatId, text: userMsg, client: client)
            }
        }

        // Возвращаем ответ сразу, обработка продолжается в фоне
        req.logger.info("✅ Webhook processed, returning OK response (background task started)")
        req.logger.info("═══════════════════════════════════════════════")
        return Response(status: .ok)
    }
}

private func extractSoraShareURL(from text: String) -> String? {
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let r = Range(match.range, in: text) {
                let urlString = String(text[r])
                if urlString.contains("sora.chatgpt.com/p/") {
                    return urlString
                }
            }
        }
    }
    if let r = text.range(of: "https://sora.chatgpt.com/p/") {
        return String(text[r.lowerBound...].split(separator: " ").first ?? Substring(""))
    }
    return nil
}

/// Получает HTML через ScrapingBee API (надёжно обходит Cloudflare)
private func fetchViaScrapingBee(url: String, apiKey: String, req: Request) async throws -> String {
    // render_js=true нужен для получения полного HTML с __NEXT_DATA__ (Next.js рендерит его через JS)
    // Увеличиваем wait до 60000ms (60 секунд) для полного рендеринга JS и получения __NEXT_DATA__
    // Добавляем wait_for для ожидания появления __NEXT_DATA__ скрипта
    let encodedUrl = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
    
    // Стратегия: пробуем с wait_for селектором для __NEXT_DATA__
    // Если это не сработает, ScrapingBee будет ждать заданное время
    var apiUrl = "https://app.scrapingbee.com/api/v1/?api_key=\(apiKey)&url=\(encodedUrl)&render_js=true&wait=60000&premium_proxy=true&block_ads=true"
    
    // Пробуем добавить wait_for (если поддерживается)
    // Ждём появления скрипта с id __NEXT_DATA__
    let waitForSelector = "script#__NEXT_DATA__"
    if let encodedSelector = waitForSelector.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        apiUrl += "&wait_for=\(encodedSelector)"
        req.logger.debug("Using wait_for selector: \(waitForSelector)")
    }
    
    req.logger.debug("ScrapingBee API URL: \(apiUrl)")
    
    // Используем HTTP клиент Vapor для асинхронного запроса с таймаутом
    let client = req.client
    let uri = URI(string: apiUrl)
    
    do {
        let response = try await client.get(uri).get()
        
        guard response.status == HTTPStatus.ok else {
            let bodyStr = response.body?.getString(at: 0, length: response.body?.readableBytes ?? 0, encoding: .utf8) ?? ""
            req.logger.error("ScrapingBee API returned status \(response.status.code): \(bodyStr.prefix(200))")
            throw Abort(.badRequest, reason: "ScrapingBee API returned status \(response.status.code)")
        }
        
        guard let body = response.body else {
            throw Abort(.badRequest, reason: "ScrapingBee returned empty body")
        }
        
        guard let html = body.getString(at: 0, length: body.readableBytes, encoding: .utf8), !html.isEmpty else {
            throw Abort(.badRequest, reason: "ScrapingBee returned empty HTML")
        }
        
        // Проверяем, не вернул ли ScrapingBee JSON с ошибкой вместо HTML
        if html.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).hasPrefix("{") {
            req.logger.warning("ScrapingBee returned JSON instead of HTML (possible error): \(html.prefix(200))")
            throw Abort(.badRequest, reason: "ScrapingBee returned error response")
        }
        
        req.logger.info("ScrapingBee returned HTML (length: \(html.count))")
        
        // Проверяем наличие __NEXT_DATA__ в HTML
        let hasNextData = html.contains("__NEXT_DATA__")
        req.logger.info("ScrapingBee HTML contains __NEXT_DATA__: \(hasNextData)")
        if !hasNextData {
            req.logger.warning("⚠️ __NEXT_DATA__ not found in ScrapingBee HTML - JS rendering may be incomplete")
        }
        
        return html
    } catch {
        req.logger.error("ScrapingBee request failed: \(error)")
        throw Abort(.badRequest, reason: "ScrapingBee request failed: \(error.localizedDescription)")
    }
}

/// Получает HTML через Playwright-сервис (локальный Docker-контейнер)
private func fetchViaPlaywright(url: String, serviceUrl: String, req: Request) async throws -> String {
    // Playwright-сервис работает на localhost:3000 (или задан через переменную окружения)
    let apiUrl = "\(serviceUrl)/fetch"
    
    req.logger.info("🎭 Calling Playwright service at \(apiUrl)...")
    
    let client = req.client
    
    var headers = HTTPHeaders()
    headers.contentType = .json
    
    let uri = URI(string: apiUrl)
    
    do {
        req.logger.info("📤 Sending POST request to Playwright service with URL: \(url.prefix(100))...")
        req.logger.info("⏱️ This may take up to 60 seconds (waiting for page load and __NEXT_DATA__)...")
        
        let response = try await client.post(uri, headers: headers) { req in
            try req.content.encode(["url": url] as [String: String])
        }.get()
        
        guard response.status == HTTPStatus.ok else {
            let bodyStr = response.body?.getString(at: 0, length: response.body?.readableBytes ?? 0, encoding: .utf8) ?? ""
            req.logger.error("Playwright service returned status \(response.status.code): \(bodyStr.prefix(200))")
            throw Abort(.badRequest, reason: "Playwright service returned status \(response.status.code)")
        }
        
        guard let body = response.body else {
            throw Abort(.badRequest, reason: "Playwright service returned empty body")
        }
        
        guard let bodyString = body.getString(at: 0, length: body.readableBytes, encoding: .utf8), !bodyString.isEmpty else {
            throw Abort(.badRequest, reason: "Playwright service returned empty response")
        }
        
        // Парсим JSON ответ
        struct PlaywrightResponse: Codable {
            let success: Bool
            let html: String?
            let hasNextData: Bool?
            let length: Int?
            let error: String?
        }
        
        guard let data = bodyString.data(using: .utf8),
              let responseObj = try? JSONDecoder().decode(PlaywrightResponse.self, from: data) else {
            throw Abort(.badRequest, reason: "Failed to parse Playwright service response")
        }
        
        guard responseObj.success, let html = responseObj.html, !html.isEmpty else {
            let errorMsg = responseObj.error ?? "Unknown error"
            req.logger.error("Playwright service returned error: \(errorMsg)")
            throw Abort(.badRequest, reason: "Playwright service error: \(errorMsg)")
        }
        
        req.logger.info("✅ Playwright service returned HTML (length: \(html.count))")
        if let hasNextData = responseObj.hasNextData {
            req.logger.info("✅ Playwright service HTML contains __NEXT_DATA__: \(hasNextData)")
            if hasNextData {
                req.logger.info("🎉 Playwright service successfully found __NEXT_DATA__! This should give us the correct UUID!")
            }
        }
        
        return html
    } catch {
        req.logger.error("Playwright service request failed: \(error)")
        throw Abort(.badRequest, reason: "Playwright service request failed: \(error.localizedDescription)")
    }
}

/// Получает HTML через ScraperAPI (БЕСПЛАТНО: 5000 запросов/месяц!)
private func fetchViaScraperAPI(url: String, apiKey: String, req: Request) async throws -> String {
    // ScraperAPI поддерживает JS-рендеринг и обход Cloudflare
    // Бесплатный план: 5000 запросов/месяц
    let encodedUrl = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
    // render=true включает JS-рендеринг (важно для __NEXT_DATA__)
    // premium=true может требовать платный план, поэтому пробуем без него сначала
    // device_type=desktop для лучшей имитации браузера
    // wait_time увеличивает время ожидания JS-рендеринга (в секундах, максимум обычно 60 для бесплатного плана)
    // Это критично для получения __NEXT_DATA__, который загружается асинхронно
    // Увеличиваем до 35 секунд для более надёжной загрузки __NEXT_DATA__
    let apiUrl = "http://api.scraperapi.com?api_key=\(apiKey)&url=\(encodedUrl)&render=true&device_type=desktop&wait_time=35"
    
    req.logger.debug("ScraperAPI URL: \(apiUrl.prefix(200))...")
    
    let client = req.client
    let uri = URI(string: apiUrl)
    
    do {
        let response = try await client.get(uri).get()
        
        guard response.status == HTTPStatus.ok else {
            let bodyStr = response.body?.getString(at: 0, length: response.body?.readableBytes ?? 0, encoding: .utf8) ?? ""
            req.logger.error("ScraperAPI returned status \(response.status.code): \(bodyStr.prefix(200))")
            throw Abort(.badRequest, reason: "ScraperAPI returned status \(response.status.code)")
        }
        
        guard let body = response.body else {
            throw Abort(.badRequest, reason: "ScraperAPI returned empty body")
        }
        
        guard let html = body.getString(at: 0, length: body.readableBytes, encoding: .utf8), !html.isEmpty else {
            throw Abort(.badRequest, reason: "ScraperAPI returned empty HTML")
        }
        
        req.logger.info("ScraperAPI returned HTML (length: \(html.count))")
        
        // Более глубокий поиск __NEXT_DATA__ в разных форматах
        let hasNextData = html.contains("__NEXT_DATA__") || 
                         html.contains("__next_data__") || 
                         html.contains("__NEXT_DATA") ||
                         html.contains("NEXT_DATA") ||
                         html.contains("%5B%5B__NEXT_DATA__%5D%5D") ||
                         html.contains("&#x5f;&#x5f;NEXT_DATA&#x5f;&#x5f;")
        
        req.logger.info("ScraperAPI HTML contains __NEXT_DATA__ (any format): \(hasNextData)")
        
        // Если не найден, пробуем извлечь через функцию extractNextDataJSON
        if !hasNextData {
            req.logger.warning("⚠️ __NEXT_DATA__ not found with simple contains check, trying deep extraction...")
            if let nextData = extractNextDataJSON(from: html) {
                req.logger.info("✅ Found __NEXT_DATA__ via deep extraction! (length: \(nextData.count))")
                // Проверяем, содержит ли он правильный UUID
                if nextData.contains("00000000-3c8c-6284-bc03-c61add5e47f1") {
                    req.logger.info("✅ Found correct UUID in __NEXT_DATA__!")
                }
            } else {
                req.logger.error("❌ __NEXT_DATA__ not found even with deep extraction - this is the core problem!")
            }
        }
        
        return html
    } catch {
        req.logger.error("ScraperAPI request failed: \(error)")
        throw Abort(.badRequest, reason: "ScraperAPI request failed: \(error.localizedDescription)")
    }
}

/// Получает HTML через Crawlbase (БЕСПЛАТНО: 1000 запросов/месяц!)
private func fetchViaCrawlbase(url: String, apiKey: String, req: Request) async throws -> String {
    // Crawlbase поддерживает JS-рендеринг и обход Cloudflare
    // Бесплатный план: 1000 запросов/месяц
    let encodedUrl = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
    // js=true включает JS-рендеринг (важно для __NEXT_DATA__)
    // wait увеличиваем до 40 секунд для надёжной загрузки __NEXT_DATA__
    // page_wait может помочь для страниц с долгой загрузкой JS
    let apiUrl = "https://api.crawlbase.com/?token=\(apiKey)&url=\(encodedUrl)&js=true&wait=40000&page_wait=5000"
    
    req.logger.debug("Crawlbase URL: \(apiUrl.prefix(200))...")
    
    let client = req.client
    let uri = URI(string: apiUrl)
    
    do {
        let response = try await client.get(uri).get()
        
        guard response.status == HTTPStatus.ok else {
            let bodyStr = response.body?.getString(at: 0, length: response.body?.readableBytes ?? 0, encoding: .utf8) ?? ""
            req.logger.error("Crawlbase returned status \(response.status.code): \(bodyStr.prefix(200))")
            throw Abort(.badRequest, reason: "Crawlbase returned status \(response.status.code)")
        }
        
        guard let body = response.body else {
            throw Abort(.badRequest, reason: "Crawlbase returned empty body")
        }
        
        guard let html = body.getString(at: 0, length: body.readableBytes, encoding: .utf8), !html.isEmpty else {
            throw Abort(.badRequest, reason: "Crawlbase returned empty HTML")
        }
        
        req.logger.info("Crawlbase returned HTML (length: \(html.count))")
        
        // Более глубокий поиск __NEXT_DATA__ в разных форматах (как в ScraperAPI)
        let hasNextData = html.contains("__NEXT_DATA__") || 
                         html.contains("__next_data__") || 
                         html.contains("__NEXT_DATA") ||
                         html.contains("NEXT_DATA") ||
                         html.contains("%5B%5B__NEXT_DATA__%5D%5D") ||
                         html.contains("&#x5f;&#x5f;NEXT_DATA&#x5f;&#x5f;")
        
        req.logger.info("Crawlbase HTML contains __NEXT_DATA__ (any format): \(hasNextData)")
        
        // Если не найден, пробуем извлечь через функцию extractNextDataJSON
        if !hasNextData {
            req.logger.warning("⚠️ Crawlbase: __NEXT_DATA__ not found with simple contains check, trying deep extraction...")
            if let nextData = extractNextDataJSON(from: html) {
                req.logger.info("✅ Crawlbase found __NEXT_DATA__ via deep extraction! (length: \(nextData.count))")
                // Проверяем, содержит ли он правильный UUID
                if nextData.contains("00000000-3c8c-6284-bc03-c61add5e47f1") {
                    req.logger.info("✅ Found correct UUID in Crawlbase __NEXT_DATA__!")
                }
            } else {
                req.logger.error("❌ Crawlbase: __NEXT_DATA__ not found even with deep extraction - JS may not have loaded!")
            }
        }
        
        return html
    } catch {
        req.logger.error("Crawlbase request failed: \(error)")
        throw Abort(.badRequest, reason: "Crawlbase request failed: \(error.localizedDescription)")
    }
}

/// Получает HTML через Browserless.io API (надёжный JS-рендеринг для получения __NEXT_DATA__)
private func fetchViaBrowserless(url: String, apiKey: String, req: Request) async throws -> String {
    // Browserless.io использует Chrome headless браузер для полного JS-рендеринга
    // Используем новый production endpoint вместо устаревшего chrome.browserless.io
    let apiUrl = "https://production-sfo.browserless.io/content?token=\(apiKey)"
    
    req.logger.debug("Browserless API URL: \(apiUrl)")
    
    // Формируем JSON body для Browserless
    // Browserless content API принимает только url и cookies (БЕЗ options - они вызывают ошибку 400)
    var requestBody: [String: Any] = [
        "url": url
    ]
    
    // ВАЖНО: Browserless content API не поддерживает options!
    // Для ожидания загрузки JS нужно использовать другой endpoint или просто надеяться,
    // что Browserless подождёт достаточно времени автоматически
    
    // Добавляем куки если есть (для обхода Cloudflare)
    if let soraCookies = Environment.get("SORA_COOKIES"), !soraCookies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        var cookieArray: [[String: String]] = []
        // Парсим куки из строки формата "cookie1=value1; cookie2=value2"
        let cookiePairs = soraCookies.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for pair in cookiePairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                cookieArray.append([
                    "name": String(parts[0]),
                    "value": String(parts[1]),
                    "domain": ".sora.chatgpt.com"
                ])
            }
        }
        if !cookieArray.isEmpty {
            requestBody["cookies"] = cookieArray
            req.logger.info("Using SORA_COOKIES with Browserless (\(cookieArray.count) cookies)")
        }
    }
    
    guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
        throw Abort(.badRequest, reason: "Failed to encode Browserless request body")
    }
    
    let client = req.client
    let uri = URI(string: apiUrl)
    
    var headers = HTTPHeaders()
    headers.add(name: "Content-Type", value: "application/json")
    
    do {
        let response = try await client.post(uri, headers: headers) { req in
            req.body = ByteBuffer(data: jsonData)
        }.get()
        
        guard response.status == HTTPStatus.ok else {
            let bodyStr = response.body?.getString(at: 0, length: response.body?.readableBytes ?? 0, encoding: .utf8) ?? ""
            req.logger.error("Browserless API returned status \(response.status.code): \(bodyStr.prefix(200))")
            throw Abort(.badRequest, reason: "Browserless API returned status \(response.status.code)")
        }
        
        guard let body = response.body else {
            throw Abort(.badRequest, reason: "Browserless returned empty body")
        }
        
        guard let html = body.getString(at: 0, length: body.readableBytes, encoding: .utf8), !html.isEmpty else {
            throw Abort(.badRequest, reason: "Browserless returned empty HTML")
        }
        
        req.logger.info("Browserless returned HTML (length: \(html.count))")
        
        // Проверяем, не заблокировал ли Cloudflare
        if html.contains("Just a moment") || html.contains("cf-browser-verification") || html.contains("Checking your browser") {
            req.logger.warning("⚠️ Browserless returned Cloudflare challenge (HTML length: \(html.count), first 200 chars: \(html.prefix(200)))")
            throw Abort(.badRequest, reason: "Browserless returned Cloudflare challenge")
        }
        
        // Проверяем наличие __NEXT_DATA__ в HTML
        let hasNextData = html.contains("__NEXT_DATA__")
        req.logger.info("Browserless HTML contains __NEXT_DATA__: \(hasNextData)")
        if !hasNextData {
            req.logger.warning("⚠️ __NEXT_DATA__ not found in Browserless HTML - JS rendering may be incomplete")
            req.logger.debug("Browserless HTML preview (first 500 chars): \(html.prefix(500))")
        }
        
        return html
    } catch {
        req.logger.error("Browserless request failed: \(error)")
        throw Abort(.badRequest, reason: "Browserless request failed: \(error.localizedDescription)")
    }
}

/// Парсит HTML страницы Sora и извлекает прямую ссылку на видео
private func parseSoraHtml(_ html: String, req: Request) throws -> String {
    // Сначала ищем все UUID на странице для отладки
    let allUUIDs = extractAllUUIDs(from: html)
    if allUUIDs.isEmpty == false {
        req.logger.info("All UUIDs found on page (\(allUUIDs.count) total): \(allUUIDs.prefix(10).joined(separator: ", "))")
    }
    
    // ДЕТАЛЬНОЕ ЛОГИРОВАНИЕ: находим ВСЕ ссылки videos.openai.com в HTML для анализа
    let allVideoUrls = extractAllVideoUrls(from: html)
    req.logger.info("📊 Found \(allVideoUrls.count) total videos.openai.com URLs in HTML")
    if allVideoUrls.count > 0 {
        // Группируем по типам
        let downloadable = allVideoUrls.filter { $0.contains("downloadable") }
        let encodings = allVideoUrls.filter { $0.contains("encodings") || $0.contains("source") }
        let azFiles = allVideoUrls.filter { $0.contains("/az/files/") }
        let drvs = allVideoUrls.filter { $0.contains("/drvs/") }
        let vgAssets = allVideoUrls.filter { $0.contains("vg-assets") }
        let thumbnails = allVideoUrls.filter { $0.contains("thumbnail") }
        
        req.logger.info("📊 URL breakdown: downloadable=\(downloadable.count), encodings/source=\(encodings.count), /az/files/=\(azFiles.count), /drvs/=\(drvs.count), vg-assets=\(vgAssets.count), thumbnails=\(thumbnails.count)")
        
        // Логируем уникальные ссылки (первые 10)
        let uniqueUrls = Array(Set(allVideoUrls)).prefix(10)
        for (idx, url) in uniqueUrls.enumerated() {
            let type = url.contains("/drvs/md/raw") ? "⚠️ WATERMARKED" :
                       url.contains("/az/files/") && !url.contains("/drvs/") ? "✅ POTENTIAL NO-WATERMARK" :
                       url.contains("downloadable") ? "🎯 DOWNLOADABLE" :
                       url.contains("encodings") || url.contains("source") ? "🎯 ENCODINGS" :
                       url.contains("thumbnail") ? "🖼️ THUMBNAIL" : "📹 OTHER"
            req.logger.debug("  [\(idx)] \(type): \(url.prefix(200))...")
        }
    }
    
    // ВАЖНО: сначала парсим JSON (__NEXT_DATA__), там могут быть приоритетные ссылки без ватермарки
    let nextJsonOpt = extractNextDataJSON(from: html)
    let hasNextData = nextJsonOpt != nil
    req.logger.debug("Sora __NEXT_DATA__ found=\(hasNextData)")
    if let nextJson = nextJsonOpt {
        req.logger.debug("Sora __NEXT_DATA__ size=\(nextJson.count)")
        // Сначала ищем в JSON напрямую (может быть JSON-escaped URL)
        if let found = extractDirectUrl(from: nextJson, logger: req.logger) { 
            req.logger.info("✅ Found URL in JSON (direct search) - this should be original without watermark: \(found)")
            return found 
        }
        // Затем рекурсивно парсим JSON структуру (downloadable_url, encodings.source.path)
        if let fromParsed = extractFromNextData(nextJson, logger: req.logger) { 
            req.logger.info("✅ Found URL in JSON (parsed structure: downloadable_url/encodings.source.path) - this should be original without watermark: \(fromParsed)")
            return fromParsed 
        }
        req.logger.warning("⚠️ __NEXT_DATA__ found but no downloadable_url or encodings.source.path in it")
    } else {
        req.logger.info("ℹ️ __NEXT_DATA__ not found - will try to use /az/files/{uuid}/raw if UUID matches main video (like nosorawm.app does, should be original without watermark)")
    }
    
    // Ищем downloadable_url и encodings.source.path напрямую в HTML (даже если __NEXT_DATA__ не найден)
    // Пробуем разные варианты кодирования и паттерны
    
    // 1. downloadable_url - разные варианты кодирования
    // КРИТИЧЕСКИ ВАЖНО: downloadable_url содержит правильный UUID оригинального видео без ватермарки!
    let downloadablePatterns = [
        #""downloadable_url"\s*:\s*"([^"]+)"#,  // Стандартный JSON
        #"downloadable_url["\s]*:[\s]*["']([^"']+)["']"#,  // С одинарными кавычками
        #"downloadableUrl["\s]*:[\s]*["']([^"']+)["']"#,  // camelCase
        #"downloadable_url["\s]*:[\s]*([^\s,}]+)"#,  // Без кавычек
        #"downloadable_url%22%3A%22([^%]+)"#,  // Percent-encoded
        #"downloadable_url["\s]*:[\s]*(&quot;|%22)([^&"]+)(&quot;|%22)"#,  // HTML entities
        #""downloadableUrl"\s*:\s*"([^"]+)"#,  // camelCase в кавычках
        #"'downloadable_url'\s*:\s*'([^']+)'"#,  // Одинарные кавычки везде
    ]
    
    for pattern in downloadablePatterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: html) {
            let url = String(html[range])
            let decoded = decodePotentiallyEncodedURL(url)
            if decoded.contains("videos.openai.com") && !decoded.contains("sora.chatgpt.com") && !decoded.contains("thumbnail") {
                req.logger.info("✅ Found downloadable_url in HTML (pattern: \(pattern.prefix(30))...): \(decoded.prefix(150))...")
                return decoded
            }
        }
    }
    
    // 2. encodings.source.path - разные варианты
    let encodingPatterns = [
        #"encodings["\s]*:[\s\S]*?"source"["\s]*:[\s\S]*?"path"["\s]*:\s*"([^"]+)"#,  // Стандартный
        #"encodings\.source\.path["\s]*:[\s]*["']([^"']+)["']"#,  // Точечная нотация
        #"encodings["\s]*\{[\s\S]*?source["\s]*\{[\s\S]*?path["\s]*:[\s]*["']([^"']+)["']"#,  // Вложенные объекты
        #"source["\s]*:[\s\S]*?path["\s]*:[\s]*["']([^"']+)["']"#,  // Без encodings
    ]
    
    for pattern in encodingPatterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: html) {
            let url = String(html[range])
            let decoded = decodePotentiallyEncodedURL(url)
            if decoded.contains("videos.openai.com") && !decoded.contains("sora.chatgpt.com") && !decoded.contains("thumbnail") && !decoded.contains("source_wm") {
                req.logger.info("✅ Found encodings.source.path in HTML (pattern: \(pattern.prefix(30))...): \(decoded.prefix(150))...")
                return decoded
            }
        }
    }
    
    // 3. Ищем window.__NEXT_DATA__, self.__next_f и другие варианты
    let nextDataPatterns = [
        #"window\.__NEXT_DATA__\s*=\s*({[^<]+})"#,
        #"self\.__next_f\s*=\s*\[([^\]]+)\]"#,
        #"__NEXT_DATA__\s*=\s*({[^<]+})"#,
        #"window\.__INITIAL_STATE__\s*=\s*({[^<]+})"#,
    ]
    
    for pattern in nextDataPatterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: html) {
            let jsonStr = String(html[range])
            req.logger.debug("Found alternative JSON pattern: \(pattern.prefix(30))..., size=\(jsonStr.count)")
            // Пробуем извлечь из этого JSON
            if let found = extractDirectUrl(from: jsonStr, logger: req.logger) {
                req.logger.info("✅ Found URL in alternative JSON pattern: \(found.prefix(150))...")
                return found
            }
            if let fromParsed = extractFromNextData(jsonStr, logger: req.logger) {
                req.logger.info("✅ Found URL in alternative JSON (parsed): \(fromParsed.prefix(150))...")
                return fromParsed
            }
        }
    }
    
    // Дополнительный поиск: ищем ссылки через анализ всех найденных URL
    // Может быть, есть рабочая ссылка без ватермарки, которую мы пропустили
    // Используем уже найденные allVideoUrls (объявлены выше)
    
    // Ищем ссылки, которые могут быть без ватермарки:
    // 1. /az/files/{uuid}/raw без /drvs/ (уже искали выше, но проверим ещё раз)
    // 2. vg-assets с src.mp4 (приоритет)
    // 3. Любые ссылки, которые не содержат /drvs/ и thumbnail
    let potentialNoWatermark = allVideoUrls.filter { url in
        url.contains("videos.openai.com") &&
        !url.contains("sora.chatgpt.com") &&
        !url.contains("thumbnail") &&
        !url.contains(".jpeg") &&
        !url.contains(".jpg") &&
        !url.contains(".png") &&
        !url.contains("/drvs/") &&
        (url.contains("/az/files/") || url.contains("vg-assets"))
    }
    
    if potentialNoWatermark.isEmpty == false {
        // Находим UUID основного видео из /drvs/md/raw для проверки
        let mainVideoUUIDs = Set(allVideoUrls.compactMap { url in
            if url.contains("/drvs/md/raw") {
                return extractUUIDFromDrvsUrl(url)
            }
            return nil
        })
        
        // ВАЖНО: ссылки с UUID, отличным от основного видео, могут быть ЛЮБЫМ медиа (аватарка, другое видео, и т.д.)
        // Без __NEXT_DATA__ мы не можем проверить, является ли ссылка оригиналом без ватермарки или просто другим медиа.
        // ВАЖНО: UUID в /az/files/{uuid}/raw МОЖЕТ отличаться от UUID в /drvs/md/raw!
        // Это потому что /drvs/md/raw - это версия С ватермаркой, а /az/files/{uuid}/raw - оригинал БЕЗ ватермарки.
        // Поэтому используем любую /az/files/{uuid}/raw ссылку с полными SAS параметрами (как nosorawm.app)
        for url in potentialNoWatermark {
            if url.contains("/az/files/") && url.contains("/raw") && !url.contains("/drvs/") {
                let uuid = extractUUIDFromDirectRaw(url) ?? ""
                // Проверяем, что есть все SAS параметры (это важно для работоспособности ссылки)
                let hasAllParams = (url.contains("?se=") || url.contains("&se=")) && 
                                   (url.contains("?sp=") || url.contains("&sp=")) && 
                                   (url.contains("?sig=") || url.contains("&sig=")) && 
                                   (url.contains("?ac=") || url.contains("&ac="))
                if hasAllParams {
                    // КРИТИЧЕСКИ ВАЖНО: UUID, который НЕ совпадает с /drvs/md/raw, имеет ВЫСШИЙ приоритет!
                    // Это потому что /drvs/md/raw - это версия С ватермаркой, а оригинал БЕЗ ватермарки имеет ДРУГОЙ UUID!
                    // Поэтому сначала возвращаем ссылки с UUID, который НЕ совпадает с main video UUID
                    let isMainVideo = !uuid.isEmpty && mainVideoUUIDs.contains(uuid)
                    if !isMainVideo {
                        req.logger.info("✅ Found /az/files/{uuid}/raw with UUID \(uuid) (NOT matching main video UUID - this is GOOD! /drvs/md/raw has watermark, this should be original without watermark). SAS params present. Using it (like nosorawm.app)!")
                        return url
                    } else {
                        req.logger.debug("Found /az/files/{uuid}/raw with UUID \(uuid) matching main video (has watermark), continuing to search for original...")
                        // Не возвращаем сразу - продолжаем поиск, может быть найден оригинал без ватермарки
                        continue
                    }
                } else {
                    req.logger.debug("Found /az/files/{uuid}/raw but missing SAS params, continuing search")
                    continue
                }
            } else if url.contains("vg-assets") {
                // vg-assets ссылки можем использовать, если они не thumbnail
                if !url.contains("thumbnail") && !url.contains(".jpeg") && !url.contains(".jpg") && !url.contains(".png") {
                    req.logger.info("Found potential no-watermark URL (vg-assets): \(url.prefix(150))...")
                    return url
                }
            }
        }
        
        // Если не нашли подходящую ссылку, используем /drvs/md/raw (гарантированно работает, хотя с ватермаркой)
        req.logger.info("No suitable no-watermark URL found, will use /drvs/md/raw (has watermark but guaranteed to work)")
    }
    
    // ВАЖНО: vg-assets НЕ работают для получения оригинального видео без ватермарки!
    // Эталонная ссылка от nosorawm.app - это /az/files/{uuid}/raw с полными SAS параметрами
    // Поэтому мы НЕ используем vg-assets, а ищем только /az/files/{uuid}/raw
    // vg-assets оставляем только как последний fallback, если вообще ничего не найдено
    
    // Fallback: ищем в HTML напрямую
    if let found = extractDirectUrl(from: html, logger: req.logger) { return found }
    
    // Пробуем найти task_id
    if let taskId = extractTaskId(from: html) {
        req.logger.info("Found task_id: \(taskId)")
        req.logger.debug("Found task_id but cannot construct vg-assets URL without SAS params")
    }
    
    let hasHost = html.contains("videos.openai.com")
    req.logger.debug("Sora HTML len=\(html.count) hasVideosHost=\(hasHost)")
    throw Abort(.notFound)
}

private func fetchDirectSoraVideoUrl(from shareUrl: String, req: Request) async throws -> String {
    req.logger.info("🔍 Starting fetchDirectSoraVideoUrl for URL: \(shareUrl)")
    // Пробуем разные сервисы для рендеринга JS в порядке приоритета
    // ВАЖНО: Добавляем retry логику - иногда нужно несколько попыток для получения __NEXT_DATA__
    
    // 1. Playwright-сервис (локальный Docker-контейнер) - ПРИОРИТЕТ #1!
    // Использует реальный браузер, должен надёжно получать __NEXT_DATA__
    let playwrightServiceUrl = Environment.get("PLAYWRIGHT_SERVICE_URL") ?? "http://localhost:3000"
    req.logger.info("🎭 Trying Playwright service first (real browser, should get __NEXT_DATA__ reliably)...")
    
    do {
        let html = try await fetchViaPlaywright(url: shareUrl, serviceUrl: playwrightServiceUrl, req: req)
        var hasNextData = html.contains("__NEXT_DATA__") || 
                         html.contains("__next_data__") || 
                         html.contains("__NEXT_DATA") ||
                         html.contains("NEXT_DATA")
        
        // Также пробуем глубокое извлечение
        if !hasNextData {
            if let _ = extractNextDataJSON(from: html) {
                hasNextData = true
                req.logger.info("✅ Playwright found __NEXT_DATA__ via deep extraction!")
            }
        }
        
        if !html.contains("Just a moment") && !html.contains("cf-browser-verification") {
            req.logger.info("Playwright success, parsing HTML...")
            do {
                let result = try parseSoraHtml(html, req: req)
                if hasNextData {
                    req.logger.info("✅ Playwright found URL with __NEXT_DATA__ (should be original without watermark): \(result.prefix(150))...")
                } else {
                    req.logger.warning("⚠️ Playwright found URL but WITHOUT __NEXT_DATA__: \(result.prefix(150))...")
                }
                return result
            } catch {
                req.logger.warning("Playwright parsing failed: \(error)")
                // Продолжаем к fallback методам
            }
        } else {
            req.logger.warning("Playwright returned Cloudflare challenge, trying alternatives...")
        }
    } catch {
        req.logger.warning("⚠️ Playwright service failed: \(error.localizedDescription) - trying alternatives...")
        // Продолжаем к fallback методам
    }
    
    // 2. Browserless.io API - ОТКЛЮЧЕН: всегда блокируется Cloudflare, даже с куками
    // Оставляем код закомментированным на случай, если ситуация изменится
    /*
    if let apiKey = Environment.get("BROWSERLESS_API_KEY"), !apiKey.isEmpty {
        req.logger.info("Trying Browserless.io API first...")
        
        // Пробуем до 3 раз для получения __NEXT_DATA__
        var lastError: Error?
        for attempt in 1...3 {
            req.logger.info("Browserless attempt \(attempt)/3...")
            
            if let html = try? await fetchViaBrowserless(url: shareUrl, apiKey: apiKey, req: req) {
                if !html.contains("Just a moment") && !html.contains("cf-browser-verification") {
                    // Проверяем наличие __NEXT_DATA__ более агрессивно (разные форматы)
                    let hasNextData = html.contains("__NEXT_DATA__") || 
                                     html.contains("\"__NEXT_DATA__\"") || 
                                     html.contains("'__NEXT_DATA__'") ||
                                     html.range(of: "__NEXT_DATA__", options: .caseInsensitive) != nil
                    
                    if hasNextData {
                        req.logger.info("✅ Browserless found __NEXT_DATA__ on attempt \(attempt)!")
                    } else {
                        req.logger.warning("⚠️ Browserless attempt \(attempt): __NEXT_DATA__ not found (HTML length: \(html.count))")
                        // Пробуем найти в разных форматах кодирования
                        let decoded = html.removingPercentEncoding ?? html
                        if decoded.contains("__NEXT_DATA__") {
                            req.logger.info("✅ Found __NEXT_DATA__ in decoded HTML!")
                        }
                    }
                    
                    req.logger.info("Browserless success, parsing HTML...")
                    do {
                        let result = try parseSoraHtml(html, req: req)
                        // Если Browserless нашёл ссылку и есть __NEXT_DATA__, это может быть оригинал без ватермарки!
                        if hasNextData {
                            req.logger.info("✅ Browserless found URL with __NEXT_DATA__ (may be original without watermark): \(result.prefix(150))...")
                        } else {
                            req.logger.info("✅ Browserless found URL (attempt \(attempt)): \(result.prefix(150))...")
                        }
                        return result
                    } catch {
                        // Если не нашёл ссылку, пробуем альтернативы только если нет __NEXT_DATA__
                        if !hasNextData && attempt < 3 {
                            req.logger.warning("Browserless attempt \(attempt) returned HTML without __NEXT_DATA__ and no URL found, retrying...")
                            // Ждём немного перед следующей попыткой
                            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 секунды
                            lastError = error
                            continue
                        } else if !hasNextData {
                            req.logger.warning("Browserless returned HTML without __NEXT_DATA__ after \(attempt) attempts, trying alternatives...")
                            lastError = error
                            break
                        } else {
                            // Если есть __NEXT_DATA__ но не нашёл ссылку - это ошибка
                            throw error
                        }
                    }
                } else {
                    req.logger.warning("Browserless attempt \(attempt) returned Cloudflare challenge")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 секунды
                        continue
                    }
                }
            } else if attempt < 3 {
                req.logger.warning("Browserless attempt \(attempt) failed, retrying...")
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 секунды
            }
        }
        
        if let error = lastError {
            req.logger.warning("Browserless failed after 3 attempts, trying alternatives...")
        }
    }
    */
    
    // 2. ScrapingBee API (если настроен) - ПРОПУСКАЕМ ИЗ-ЗА ЛИМИТА, используем бесплатные альтернативы
    // Раскомментируй если нужно будет использовать ScrapingBee
    /*
    if let apiKey = Environment.get("SCRAPINGBEE_API_KEY"), !apiKey.isEmpty {
        req.logger.info("Trying ScrapingBee API...")
        
        // Пробуем до 3 раз для получения __NEXT_DATA__
        var lastError: Error?
        for attempt in 1...3 {
            req.logger.info("ScrapingBee attempt \(attempt)/3...")
            
            if let html = try? await fetchViaScrapingBee(url: shareUrl, apiKey: apiKey, req: req) {
                if !html.contains("Just a moment") && !html.contains("cf-browser-verification") {
                    // Проверяем наличие __NEXT_DATA__ более агрессивно
                    let hasNextData = html.contains("__NEXT_DATA__") || 
                                     html.contains("\"__NEXT_DATA__\"") || 
                                     html.range(of: "__NEXT_DATA__", options: .caseInsensitive) != nil
                    
                    if hasNextData {
                        req.logger.info("✅ ScrapingBee found __NEXT_DATA__ on attempt \(attempt)!")
                    } else {
                        req.logger.warning("⚠️ ScrapingBee attempt \(attempt): __NEXT_DATA__ not found (HTML length: \(html.count))")
                        let decoded = html.removingPercentEncoding ?? html
                        if decoded.contains("__NEXT_DATA__") {
                            req.logger.info("✅ Found __NEXT_DATA__ in decoded HTML!")
                        }
                    }
                    
                    req.logger.info("ScrapingBee success, parsing HTML...")
                    do {
                        let result = try parseSoraHtml(html, req: req)
                        // Если ScrapingBee нашёл ссылку и есть __NEXT_DATA__, это может быть оригинал без ватермарки!
                        if hasNextData {
                            req.logger.info("✅ ScrapingBee found URL with __NEXT_DATA__ (may be original without watermark): \(result.prefix(150))...")
                        } else {
                            req.logger.info("✅ ScrapingBee found URL (attempt \(attempt)): \(result.prefix(150))...")
                        }
                        return result
                    } catch {
                        // Если не нашёл ссылку, пробуем альтернативы только если нет __NEXT_DATA__
                        if !hasNextData && attempt < 3 {
                            req.logger.warning("ScrapingBee attempt \(attempt) returned HTML without __NEXT_DATA__ and no URL found, retrying...")
                            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 секунды (ScrapingBee медленнее)
                            lastError = error
                            continue
                        } else if !hasNextData {
                            req.logger.warning("ScrapingBee returned HTML without __NEXT_DATA__ after \(attempt) attempts, trying alternatives...")
                            lastError = error
                            break
                        } else {
                            // Если есть __NEXT_DATA__ но не нашёл ссылку - это ошибка
                            throw error
                        }
                    }
                } else {
                    req.logger.warning("ScrapingBee attempt \(attempt) returned Cloudflare challenge")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 секунды
                        continue
                    }
                }
            } else if attempt < 3 {
                req.logger.warning("ScrapingBee attempt \(attempt) failed, retrying...")
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 секунды
            }
        }
        
        if let error = lastError {
            req.logger.warning("ScrapingBee failed after 3 attempts, trying alternatives...")
        }
    }
    */
    
    // 3. ScraperAPI (если настроен) - БЕСПЛАТНО: 5000 запросов/месяц!
    if let apiKey = Environment.get("SCRAPERAPI_API_KEY"), !apiKey.isEmpty {
        req.logger.info("Trying ScraperAPI (free tier: 5000 requests/month)...")
        var scraperApiHasNextData = false
        var scraperApiResult: String? = nil
        
        if let html = try? await fetchViaScraperAPI(url: shareUrl, apiKey: apiKey, req: req) {
            // Используем улучшенную проверку __NEXT_DATA__ (как в fetchViaScraperAPI)
            scraperApiHasNextData = html.contains("__NEXT_DATA__") || 
                                    html.contains("__next_data__") || 
                                    html.contains("__NEXT_DATA") ||
                                    html.contains("NEXT_DATA") ||
                                    html.contains("%5B%5B__NEXT_DATA__%5D%5D") ||
                                    html.contains("&#x5f;&#x5f;NEXT_DATA&#x5f;&#x5f;")
            
            // Также пробуем глубокое извлечение
            if !scraperApiHasNextData {
                if let _ = extractNextDataJSON(from: html) {
                    scraperApiHasNextData = true
                    req.logger.info("✅ ScraperAPI found __NEXT_DATA__ via deep extraction!")
                }
            }
            
            if scraperApiHasNextData {
                req.logger.info("✅ ScraperAPI found __NEXT_DATA__!")
            } else {
                req.logger.warning("⚠️ ScraperAPI did NOT find __NEXT_DATA__ - this is the core problem!")
            }
            
            if !html.contains("Just a moment") && !html.contains("cf-browser-verification") {
                req.logger.info("ScraperAPI success, parsing HTML...")
                do {
                    scraperApiResult = try parseSoraHtml(html, req: req)
                    if scraperApiHasNextData {
                        req.logger.info("✅ ScraperAPI found URL with __NEXT_DATA__ (may be original without watermark): \(scraperApiResult!.prefix(150))...")
                    } else {
                        req.logger.warning("⚠️ ScraperAPI found URL but WITHOUT __NEXT_DATA__ (likely watermarked): \(scraperApiResult!.prefix(150))...")
                    }
                } catch {
                    req.logger.warning("ScraperAPI parsing failed: \(error)")
                }
            }
        }
        
        // КРИТИЧЕСКИ ВАЖНО: Если ScraperAPI не нашёл __NEXT_DATA__, пробуем Crawlbase как альтернативу
        // Это может дать правильный UUID, который есть только в __NEXT_DATA__
        if !scraperApiHasNextData, let crawlbaseKey = Environment.get("CRAWLBASE_API_KEY"), !crawlbaseKey.isEmpty {
            req.logger.info("🔄 Trying Crawlbase as alternative (ScraperAPI didn't find __NEXT_DATA__ - this is critical for getting correct UUID!)...")
            do {
                let html = try await fetchViaCrawlbase(url: shareUrl, apiKey: crawlbaseKey, req: req)
                // Используем улучшенную проверку (уже сделана в fetchViaCrawlbase, но дублируем для логики)
                var hasNextData = html.contains("__NEXT_DATA__") || 
                                  html.contains("__next_data__") || 
                                  html.contains("__NEXT_DATA") ||
                                  html.contains("NEXT_DATA") ||
                                  html.contains("%5B%5B__NEXT_DATA__%5D%5D") ||
                                  html.contains("&#x5f;&#x5f;NEXT_DATA&#x5f;&#x5f;")
                
                // Также пробуем глубокое извлечение
                if !hasNextData {
                    if let _ = extractNextDataJSON(from: html) {
                        hasNextData = true
                        req.logger.info("✅ Crawlbase found __NEXT_DATA__ via deep extraction!")
                    }
                }
                
                if hasNextData {
                    req.logger.info("✅ Crawlbase found __NEXT_DATA__! This should give us the correct UUID!")
                }
                
                if !html.contains("Just a moment") && !html.contains("cf-browser-verification") {
                    req.logger.info("Crawlbase success, parsing HTML...")
                    do {
                        let result = try parseSoraHtml(html, req: req)
                        if hasNextData {
                            req.logger.info("✅ Crawlbase found URL with __NEXT_DATA__ (should be original without watermark): \(result.prefix(150))...")
                            return result
                        } else {
                            req.logger.warning("⚠️ Crawlbase found URL but WITHOUT __NEXT_DATA__: \(result.prefix(150))...")
                        }
                    } catch {
                        req.logger.warning("Crawlbase parsing failed: \(error)")
                    }
                }
            } catch {
                // Crawlbase может вернуть ошибку 520 (Cloudflare блокирует), но это не критично
                // если у нас уже есть результат от ScraperAPI
                req.logger.warning("⚠️ Crawlbase failed: \(error.localizedDescription) - continuing with ScraperAPI result if available")
            }
        } else if !scraperApiHasNextData {
            req.logger.error("❌ CRAWLBASE_API_KEY not configured! Cannot get correct UUID without __NEXT_DATA__!")
        }
        
        // Если получили результат от ScraperAPI (даже без __NEXT_DATA__), возвращаем его
        if let result = scraperApiResult {
            return result
        }
    }
    
    // 5. Fallback: используем системный curl с улучшенными заголовками
    // Это последняя попытка - curl не рендерит JS, поэтому __NEXT_DATA__ может отсутствовать
    req.logger.info("Trying curl as final fallback (no JS rendering, __NEXT_DATA__ may be missing)...")
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    
    // Улучшенные заголовки для лучшего обхода Cloudflare
    var curlArgs = [
        "-s", "-L", // silent, follow redirects
        "--max-time", "30", // Увеличили таймаут до 30 секунд
        "--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "--header", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        "--header", "Accept-Language: en-US,en;q=0.9",
        "--header", "Accept-Encoding: gzip, deflate, br",
        "--header", "Referer: https://sora.chatgpt.com/",
        "--header", "Origin: https://sora.chatgpt.com",
        "--header", "Cache-Control: no-cache",
        "--header", "Pragma: no-cache",
        "--header", "Sec-Fetch-Dest: document",
        "--header", "Sec-Fetch-Mode: navigate",
        "--header", "Sec-Fetch-Site: same-origin",
        "--header", "Sec-Fetch-User: ?1",
        "--header", "DNT: 1",
        "--header", "Upgrade-Insecure-Requests: 1",
        "--compressed", // Поддержка gzip/deflate
        shareUrl
    ]
    
    // Добавляем куки если есть
    if let soraCookies = Environment.get("SORA_COOKIES"), !soraCookies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        curlArgs.insert("--header", at: curlArgs.count - 1)
        curlArgs.insert("Cookie: \(soraCookies)", at: curlArgs.count - 1)
        req.logger.info("Using SORA_COOKIES with curl")
    }
    
    process.arguments = curlArgs
    
    let pipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = pipe
    process.standardError = errorPipe
    
    do {
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            req.logger.error("curl failed with status \(process.terminationStatus): \(errorMsg)")
            throw Abort(.badRequest, reason: "Не удалось загрузить страницу Sora")
        }
        
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let html = String(data: outputData, encoding: .utf8), !html.isEmpty else {
            req.logger.error("curl returned empty output")
            throw Abort(.badRequest, reason: "Пустой ответ от Sora")
        }
        
        req.logger.debug("curl fetched HTML (length: \(html.count))")
        
        // Проверяем, не заблокировал ли Cloudflare
        if html.contains("Just a moment") || html.contains("cf-browser-verification") {
            req.logger.error("Cloudflare challenge detected in HTML")
            throw Abort(.badRequest, reason: "Cloudflare блокирует запрос. Попробуйте обновить куки в config/.env или включить VPN на США.")
        }
        
        // Парсим HTML
        return try parseSoraHtml(html, req: req)
        
    } catch {
        req.logger.error("Failed to fetch Sora page via curl: \(error)")
        throw Abort(.badRequest, reason: "Не удалось загрузить страницу Sora: \(error.localizedDescription)")
    }
}

private func extractDirectUrl(from html: String, logger: Logger? = nil) -> String? {
    // 1) Прямая ссылка в чистом виде
    let mp4Pattern = #"https://videos\.openai\.com[^\s"'<>]+?src\.mp4[^\s"'<>]*"#
    if let found = firstMatch(in: html, pattern: mp4Pattern) { return found }
    let hlsPattern = #"https://videos\.openai\.com[^\s"'<>]+?hls\.m3u8[^\s"'<>]*"#
    if let found = firstMatch(in: html, pattern: hlsPattern) { return found }

    // 1b) Ветка vg-assets - учитываем и /az/vg-assets/
    let vgAssetsPattern = #"https://videos\.openai\.com(/az)?/vg-assets/[^\s"'<>\\]+"#
    if let vg = firstMatch(in: html, pattern: vgAssetsPattern) {
        let decoded = decodePotentiallyEncodedURL(vg)
        if decoded.contains("src.mp4") || decoded.contains("m3u8") { return decoded }
    }

    // 2) JSON-escaped: https:\/\/videos.openai.com..." (захватываем до ближайшей кавычки)
    let jsonEscapedPattern = #"https:\/\/videos\.openai\.com[^"]+"#
    if let rawJsonEscaped = firstMatch(in: html, pattern: jsonEscapedPattern) {
        let decoded = decodePotentiallyEncodedURL(rawJsonEscaped)
        if decoded.contains("src.mp4") || decoded.contains("hls.m3u8") { return decoded }
    }

    // 3) Percent-encoded: https%3A%2F%2Fvideos.openai.com...
    let percentEncodedPattern = #"https%3A%2F%2Fvideos\.openai\.com[^&"'<>\s]+"#
    if let rawPercent = firstMatch(in: html, pattern: percentEncodedPattern) {
        let decoded = decodePotentiallyEncodedURL(rawPercent)
        if decoded.contains("src.mp4") || decoded.contains("hls.m3u8") { return decoded }
    }

    // 3b) Percent-encoded для vg-assets - учитываем и /az/vg-assets/
    let vgPercentPattern = #"https%3A%2F%2Fvideos\.openai\.com(%2Faz)?%2Fvg-assets%2F[^&"'<>\s]+"#
    if let rawVG = firstMatch(in: html, pattern: vgPercentPattern) {
        let decoded = decodePotentiallyEncodedURL(rawVG)
        if decoded.contains("src.mp4") || decoded.contains("m3u8") { return decoded }
    }

    // 4) Разрешаем обратные слэши внутри матча до кавычки (широкий захват)
    let relaxedPattern = #"https://videos\.openai\.com[^"]+"#
    if let rawRelaxed = firstMatch(in: html, pattern: relaxedPattern) {
        let decoded = decodePotentiallyEncodedURL(rawRelaxed)
        if decoded.contains("src.mp4") || decoded.contains("hls.m3u8") { return decoded }
    }

    // 5) OpenGraph meta
    let ogMetaPattern = #"<meta[^>]+property=["']og:video["'][^>]+content=["'](https://videos\.openai\.com[^"']+(?:src\.mp4|hls\.m3u8)[^"']*)["'][^>]*>"#
    if let ogURL = firstCapture(in: html, pattern: ogMetaPattern) {
        return decodePotentiallyEncodedURL(ogURL)
    }

    // 6) Собираем все кандидаты со хоста и выбираем лучший
    // Используем несколько паттернов для более надёжного извлечения URL
    // ВАЖНО: НЕ останавливаемся на `)`, `]`, `,` - они могут быть внутри URL параметров
    // Паттерн 1: как в extractAllVideoUrls - останавливается только на пробелах, кавычках и тегах
    let anyUrlPattern1 = #"https://videos\.openai\.com[^\s"'<>]+"#
    // Паттерн 2: до закрывающей кавычки (для JSON в атрибутах) - аналогично паттерну 1
    let anyUrlPattern2 = #"https://videos\.openai\.com[^"'\s<>]+"#
    // Паттерн 3: JSON-escaped с обратными слэшами
    let anyUrlPattern3 = #"https:\\?/\\?/videos\.openai\.com[^"\\\s]+"#
    
    var rawCandidatesSet = Set<String>()
    let matches1 = allMatches(in: html, pattern: anyUrlPattern1)
    let matches2 = allMatches(in: html, pattern: anyUrlPattern2)
    let matches3 = allMatches(in: html, pattern: anyUrlPattern3)
    rawCandidatesSet.formUnion(matches1)
    rawCandidatesSet.formUnion(matches2)
    rawCandidatesSet.formUnion(matches3)
    let rawCandidates = Array(rawCandidatesSet)
    
    logger?.debug("URL extraction: pattern1=\(matches1.count), pattern2=\(matches2.count), pattern3=\(matches3.count), unique=\(rawCandidates.count)")
    if rawCandidates.isEmpty == false {
        let decoded = rawCandidates.map { decodePotentiallyEncodedURL($0) }
        // Исключаем thumbnail, jpeg, png и другие не-видео файлы, а также ссылки на sora.chatgpt.com
        let filtered = decoded.filter { url in
            !url.contains("thumbnail") && 
            !url.contains(".jpeg") && 
            !url.contains(".jpg") && 
            !url.contains(".png") &&
            !url.contains(".webp") &&
            !url.contains("thumbnail.jpeg") &&
            !url.contains("sora.chatgpt.com") // Исключаем ссылки на Sora
        }
        // Приоритет: /az/files/{id}/raw (БЕЗ /drvs/ - оригинал без ватермарки!) > vg-assets/.../src.mp4 > другие src.mp4 > m3u8 > vg-assets > /drvs/*/raw (НЕ md) > /drvs/md/raw (fallback)
        // Ищем ВСЕ прямые ссылки /az/files/{uuid}/raw (без /drvs/) - сначала без фильтра по параметрам
        let allDirectRawCandidates = filtered.filter { url in
            url.contains("/az/files/") && 
            url.contains("/raw") && 
            !url.contains("/drvs/")
        }
        
        // Логируем все кандидаты для отладки
        if allDirectRawCandidates.isEmpty == false {
            logger?.info("Found \(allDirectRawCandidates.count) direct /az/files/{id}/raw URLs (all candidates, before filtering)")
            for (idx, url) in allDirectRawCandidates.enumerated() {
                let uuid = extractUUIDFromDirectRaw(url) ?? "unknown"
                let hasSe = url.contains("?se=") || url.contains("&se=")
                let hasSp = url.contains("?sp=") || url.contains("&sp=")
                let hasSv = url.contains("?sv=") || url.contains("&sv=")
                let hasSr = url.contains("?sr=") || url.contains("&sr=")
                let hasSig = url.contains("?sig=") || url.contains("&sig=")
                let hasAc = url.contains("?ac=") || url.contains("&ac=")
                let valid = hasSe && hasSp && hasSv && hasSr && hasSig && hasAc
                logger?.debug("  [\(idx)] UUID=\(uuid) valid=\(valid) | se=\(hasSe) sp=\(hasSp) sv=\(hasSv) sr=\(hasSr) sig=\(hasSig) ac=\(hasAc) | URL: \(url.prefix(250))...")
            }
        }
        
        // Фильтруем только те, у которых есть хотя бы базовые параметры (sp, sig, ac)
        let allDirectRaw = allDirectRawCandidates.filter { url in
            (url.contains("?sp=") || url.contains("&sp=")) && 
            (url.contains("?sig=") || url.contains("&sig=")) && 
            (url.contains("?ac=") || url.contains("&ac="))
        }
        
        if allDirectRaw.isEmpty == false {
            // ВАЖНО: /az/files/{uuid}/raw БЕЗ /drvs/ могут быть оригиналом без ватермарки,
            // НО только если они получены из __NEXT_DATA__ с downloadable_url или encodings.source.path.
            // Если __NEXT_DATA__ не найден, эти ссылки МОГУТ иметь ватермарку, но могут быть и оригиналом.
            // Поэтому попробуем использовать их, если UUID совпадает с основным видео.
            let hasNextData = html.contains("__NEXT_DATA__")
            if !hasNextData {
                logger?.info("ℹ️ __NEXT_DATA__ not found in HTML - will try to use /az/files/{uuid}/raw links if UUID matches main video (like nosorawm.app does, should be original without watermark)")
            }
            
            // Используем /az/files/{uuid}/raw даже если __NEXT_DATA__ не найден - проверим UUID и работоспособность
            if true { // Теперь всегда пробуем, не только если __NEXT_DATA__ найден
                logger?.info("Found \(allDirectRaw.count) direct /az/files/{id}/raw URLs (after basic filter: sp, sig, ac). Will try to use them if UUID matches main video (__NEXT_DATA__ found=\(hasNextData))")
                
                // ВАЖНО: Находим UUID основного видео из /drvs/md/raw (это гарантированно видео этой страницы)
                let mainVideoUUIDs = Set(filtered.compactMap { url in
                    if url.contains("/drvs/md/raw") {
                        return extractUUIDFromDrvsUrl(url)
                    }
                    return nil
                })
                logger?.debug("Main video UUIDs from /drvs/md/raw: \(mainVideoUUIDs.joined(separator: ", "))")
                
                // Сортируем: ВЫСШИЙ приоритет - UUID с префиксом 00000000- (они часто ведут к оригиналу без ватермарки, как в nosorawm.app)
                // КРИТИЧЕСКИ ВАЖНО: UUID, который НЕ совпадает с /drvs/md/raw, имеет ВЫСШИЙ приоритет!
                // Это потому что /drvs/md/raw - это версия С ватермаркой, а оригинал БЕЗ ватермарки имеет ДРУГОЙ UUID!
                let sorted = allDirectRaw.sorted { url1, url2 in
                    let uuid1 = extractUUIDFromDirectRaw(url1) ?? ""
                    let uuid2 = extractUUIDFromDirectRaw(url2) ?? ""
                    
                    // Приоритет 1: UUID с префиксом 00000000- (как в рабочей ссылке от nosorawm.app)
                    let pref1 = uuid1.hasPrefix("00000000-")
                    let pref2 = uuid2.hasPrefix("00000000-")
                    if pref1 && !pref2 { return true }
                    if !pref1 && pref2 { return false }
                    
                    // Приоритет 2: UUID, который НЕ совпадает с /drvs/md/raw (это оригинал БЕЗ ватермарки!)
                    // UUID, который совпадает с /drvs/md/raw - это версия С ватермаркой, не нужна!
                    let isMain1 = mainVideoUUIDs.contains(uuid1)
                    let isMain2 = mainVideoUUIDs.contains(uuid2)
                    if !isMain1 && isMain2 { return true }  // uuid1 НЕ main - приоритет выше!
                    if isMain1 && !isMain2 { return false } // uuid2 НЕ main - приоритет выше!
                    
                    return url1 < url2
                }
                
                // Дополнительная валидация: проверяем, что ссылка содержит все обязательные SAS-параметры
                let validated = sorted.filter { url in
                    // Проверяем наличие всех обязательных параметров для Azure Blob SAS
                    // Первый параметр может начинаться с ? или &, остальные с &
                    (url.contains("?se=") || url.contains("&se=")) &&  // Signed Expiry
                    (url.contains("?sp=") || url.contains("&sp=")) &&  // Signed Permissions
                    (url.contains("?sv=") || url.contains("&sv=")) &&  // Signed Version
                    (url.contains("?sr=") || url.contains("&sr=")) &&  // Signed Resource
                    (url.contains("?sig=") || url.contains("&sig=")) && // Signature
                    (url.contains("?ac=") || url.contains("&ac="))     // Account
                }
                
                // Детальное логирование всех валидных ссылок для отладки
                if validated.isEmpty == false {
                    logger?.info("📋 Found \(validated.count) validated /az/files/{uuid}/raw URLs with full SAS params:")
                    for (idx, url) in validated.enumerated() {
                        let uuid = extractUUIDFromDirectRaw(url) ?? "unknown"
                        logger?.info("  [\(idx)] UUID=\(uuid) | URL: \(url.prefix(200))...")
                    }
                }
                
                // ВАЖНО: nosorawm.app работает именно так - использует /az/files/{uuid}/raw ссылки,
                // которые они находят на странице, даже без __NEXT_DATA__. Эти ссылки ДОЛЖНЫ работать!
                // КЛЮЧЕВОЙ ИНСАЙТ: UUID в /az/files/{uuid}/raw МОЖЕТ отличаться от UUID в /drvs/md/raw!
                // Это потому что /drvs/md/raw - это версия С ватермаркой, а /az/files/{uuid}/raw - оригинал БЕЗ ватермарки.
                
                // Пытаемся найти правильный UUID из приоритетных источников (downloadable_url, encodings.source.path)
                var preferredUUID: String? = nil
                if hasNextData, let nextJson = extractNextDataJSON(from: html) {
                    // Ищем downloadable_url или encodings.source.path в __NEXT_DATA__
                    if let downloadableUrl = extractDirectUrl(from: nextJson, logger: logger) {
                        preferredUUID = extractUUIDFromDirectRaw(downloadableUrl)
                        logger?.info("🎯 Extracted preferred UUID from downloadable_url in __NEXT_DATA__: \(preferredUUID ?? "none")")
                    }
                    if preferredUUID == nil, let encodingPath = extractFromNextData(nextJson, logger: logger) {
                        preferredUUID = extractUUIDFromDirectRaw(encodingPath)
                        logger?.info("🎯 Extracted preferred UUID from encodings.source.path in __NEXT_DATA__: \(preferredUUID ?? "none")")
                    }
                }
                
                // Также проверяем HTML напрямую для downloadable_url и encodings.source.path
                if preferredUUID == nil {
                    for pattern in [
                        #""downloadable_url"\s*:\s*"([^"]+)"#,
                        #"encodings["\s]*:[\s\S]*?"source"["\s]*:[\s\S]*?"path"["\s]*:\s*"([^"]+)"#
                    ] {
                        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                           match.numberOfRanges > 1,
                           let range = Range(match.range(at: 1), in: html) {
                            let url = String(html[range])
                            let decoded = decodePotentiallyEncodedURL(url)
                            if decoded.contains("/az/files/") && decoded.contains("/raw") {
                                preferredUUID = extractUUIDFromDirectRaw(decoded)
                                logger?.info("🎯 Extracted preferred UUID from HTML pattern: \(preferredUUID ?? "none")")
                                break
                            }
                        }
                    }
                }
                
                // КРИТИЧЕСКИ ВАЖНО: Если preferred UUID не найден, ищем ВСЕ UUID в HTML, которые НЕ совпадают с main UUID
                // Правильный UUID оригинального видео должен отличаться от UUID в /drvs/md/raw!
                if preferredUUID == nil {
                    let allUUIDsInHtml = extractAllUUIDs(from: html)
                    let uniqueUUIDs = Array(Set(allUUIDsInHtml))
                    logger?.info("🔍 Found \(uniqueUUIDs.count) unique UUIDs in HTML: \(uniqueUUIDs.joined(separator: ", "))")
                    logger?.info("📋 Main video UUIDs (from /drvs/md/raw, have watermark): \(mainVideoUUIDs.joined(separator: ", "))")
                    
                    // Ищем UUID, который НЕ совпадает с main video UUID и начинается с 00000000-
                    // Это может быть правильный UUID оригинального видео!
                    let candidateUUIDs = uniqueUUIDs.filter { uuid in
                        uuid.hasPrefix("00000000-") && !mainVideoUUIDs.contains(uuid)
                    }
                    
                    if candidateUUIDs.isEmpty == false {
                        logger?.info("🎯 Found \(candidateUUIDs.count) candidate UUIDs (00000000- prefix, NOT matching main video - should be original without watermark): \(candidateUUIDs.joined(separator: ", "))")
                        
                        // Пробуем найти ссылку с этим UUID в validated URLs
                        for candidateUUID in candidateUUIDs {
                            if let urlWithUUID = validated.first(where: { extractUUIDFromDirectRaw($0) == candidateUUID }) {
                                logger?.info("✅ FOUND! URL with candidate UUID \(candidateUUID) (NOT matching main video - should be original without watermark): \(urlWithUUID.prefix(200))...")
                                preferredUUID = candidateUUID
                                break
                            }
                        }
                        
                        // Если не нашли готовую ссылку, но нашли UUID - это важная информация для отладки
                        if preferredUUID == nil {
                            logger?.warning("⚠️ Found candidate UUIDs (\(candidateUUIDs.joined(separator: ", "))) but no corresponding /az/files/{uuid}/raw links with full SAS params found")
                            logger?.warning("⚠️ This means the correct UUID exists in HTML but doesn't have a complete /az/files/{uuid}/raw link with all SAS params")
                        }
                    } else {
                        logger?.warning("⚠️ No candidate UUIDs found! All UUIDs in HTML either match main video UUID or don't have 00000000- prefix")
                        logger?.warning("⚠️ The correct UUID (00000000-3c8c-6284-bc03-c61add5e47f1) is NOT in HTML - it's only in __NEXT_DATA__ which didn't load!")
                    }
                }
                
                if validated.isEmpty == false {
                    // Если есть preferred UUID, используем ссылку с этим UUID
                    if let preferredUUID = preferredUUID,
                       let preferredUrl = validated.first(where: { extractUUIDFromDirectRaw($0) == preferredUUID }) {
                        logger?.info("✅ Using /az/files/{uuid}/raw with preferred UUID \(preferredUUID) from downloadable_url/encodings.source.path. This should be original without watermark!")
                        return preferredUrl
                    }
                    
                    // Ищем ссылку с UUID, который НЕ совпадает с main video UUID (это оригинал без ватермарки!)
                    let nonMainUrls = validated.filter { url in
                        let uuid = extractUUIDFromDirectRaw(url) ?? ""
                        return !mainVideoUUIDs.contains(uuid)
                    }
                    
                    if nonMainUrls.isEmpty == false {
                        // Нашли ссылку с UUID, который НЕ совпадает с main - это оригинал!
                        let bestUrl = nonMainUrls.first!
                        let bestUUID = extractUUIDFromDirectRaw(bestUrl) ?? ""
                        logger?.info("✅ Found /az/files/{uuid}/raw with UUID \(bestUUID) (NOT matching main video UUID - this is GOOD! /drvs/md/raw has watermark, this should be original without watermark). Full SAS params present. Using it (like nosorawm.app does)!")
                        return bestUrl
                    }
                    
                    // Если все UUID совпадают с main, пробуем использовать ПОСЛЕДНИЙ найденный
                    // (может быть он появился позже в HTML и является оригиналом, но его UUID случайно совпал)
                    // Или пробуем все найденные по очереди, начиная с последнего
                    if validated.count > 1 {
                        logger?.warning("⚠️ All found UUIDs match main video (likely have watermark). Trying last found URL - may be original despite matching UUID: \(validated.last!.prefix(200))...")
                        return validated.last!
                    }
                    
                    // Если только одна ссылка и она совпадает с main - используем её как fallback
                    let bestUrl = validated.first!
                    let bestUUID = extractUUIDFromDirectRaw(bestUrl) ?? ""
                    logger?.warning("⚠️ Found /az/files/{uuid}/raw with UUID \(bestUUID) matching main video (has watermark, but no better option found). Full SAS params present. Using it as fallback.")
                    return bestUrl
                } else {
                    logger?.warning("❌ Found \(sorted.count) direct /az/files/{id}/raw URLs but none passed validation (missing SAS params), falling back to /drvs/md/raw")
                }
            }
        }
        
        // Находим UUID основного видео для проверки всех ссылок
        let mainVideoUUIDs = Set(filtered.compactMap { url in
            if url.contains("/drvs/md/raw") {
                return extractUUIDFromDrvsUrl(url)
            }
            return nil
        })
        
        // Если не нашли готовую ссылку с полными параметрами, не конструируем - это даст ошибку Signature
        // Вместо этого возвращаем /drvs/md/raw (хотя с ватермаркой, но работает)
        if let mdRaw = filtered.first(where: { $0.contains("/drvs/md/raw") }) {
            logger?.warning("No direct /az/files/{id}/raw found with full params, returning /drvs/md/raw (has watermark)")
            return mdRaw
        }
        
        // Примечание: больше НЕ конструируем ссылки /az/files/{uuid}/raw из частей,
        // так как SAS-токены специфичны для каждого пути и перенос параметров даст ошибку Signature.
        // Используем только готовые ссылки, найденные на странице.
        // ВАЖНО: Проверяем UUID для всех ссылок с /az/files/ - не используем ссылки с другим UUID
        if let vgAssets = filtered.first(where: { url in
            url.contains("vg-assets") && url.contains("src.mp4") && 
            (!url.contains("/az/files/") || mainVideoUUIDs.contains(extractUUIDFromDirectRaw(url) ?? ""))
        }) { return vgAssets }
        
        if let best = filtered.first(where: { url in
            url.contains("src.mp4") && !url.contains("/drvs/") &&
            (!url.contains("/az/files/") || mainVideoUUIDs.contains(extractUUIDFromDirectRaw(url) ?? ""))
        }) { return best }
        
        if let hls = filtered.first(where: { url in
            url.contains("m3u8") &&
            (!url.contains("/az/files/") || mainVideoUUIDs.contains(extractUUIDFromDirectRaw(url) ?? ""))
        }) { return hls }
        
        if let vgAny = filtered.first(where: { url in
            url.contains("vg-assets") && url.contains("/videos/") &&
            (!url.contains("/az/files/") || mainVideoUUIDs.contains(extractUUIDFromDirectRaw(url) ?? ""))
        }) { return vgAny }
        
        if let vgAny2 = filtered.first(where: { url in
            url.contains("vg-assets") &&
            (!url.contains("/az/files/") || mainVideoUUIDs.contains(extractUUIDFromDirectRaw(url) ?? ""))
        }) { return vgAny2 }
        // Ищем /drvs/*/raw, но НЕ md (md = с ватермаркой), приоритет: hd > sd > raw > другие
        let drvsVariants = filtered.filter { $0.contains("/drvs/") && $0.contains("/raw") }
        if drvsVariants.isEmpty == false {
            logger?.debug("Found /drvs/*/raw variants: \(drvsVariants.joined(separator: " | "))")
        }
        if let hdRaw = filtered.first(where: { $0.contains("/drvs/hd/raw") }) { return hdRaw }
        if let sdRaw = filtered.first(where: { $0.contains("/drvs/sd/raw") }) { return sdRaw }
        if let rawOnly = filtered.first(where: { $0.contains("/drvs/raw") && !$0.contains("/drvs/md/raw") && !$0.contains("/drvs/hd/raw") && !$0.contains("/drvs/sd/raw") }) { return rawOnly }
        // /drvs/md/raw - с ватермаркой, используем только если ничего другого нет
        if let mdRaw = filtered.first(where: { $0.contains("/drvs/md/raw") }) { return mdRaw }
        
        // ВАЖНО: Проверяем UUID для всех ссылок с /az/files/ - не используем ссылки с другим UUID
        if let mp4 = filtered.first(where: { url in
            url.contains(".mp4") &&
            (!url.contains("/az/files/") || mainVideoUUIDs.contains(extractUUIDFromDirectRaw(url) ?? ""))
        }) { return mp4 }
        let toLog = filtered.prefix(3).joined(separator: " | ")
        logger?.debug("Sora candidates (filtered): \(toLog)")
        // Если ничего не нашли, логируем все кандидаты для отладки
        if filtered.isEmpty {
            let allLog = decoded.prefix(5).joined(separator: " | ")
            logger?.debug("Sora all candidates (no video found): \(allLog)")
        }
    }

    return nil
}

// Вытаскивает JSON из Next.js data (улучшенный поиск в разных форматах)
private func extractNextDataJSON(from html: String) -> String? {
    // Стратегия 1: Стандартный формат <script id="__NEXT_DATA__">...</script>
    // Разные варианты атрибутов и кавычек, многострочный JSON
    let pattern1 = #"<script[^>]*id=['\"]__NEXT_DATA__['\"][^>]*>\s*(\{[\s\S]*?\})\s*</script>"#
    if let result = firstCapture(in: html, pattern: pattern1) {
        return result
    }
    
    // Стратегия 2: window.__NEXT_DATA__ = {...}
    let pattern2 = #"window\.__NEXT_DATA__\s*=\s*(\{[\s\S]*?\})\s*;"#
    if let result = firstCapture(in: html, pattern: pattern2) {
        return result
    }
    
    // Стратегия 3: Просто __NEXT_DATA__ = {...} (без window)
    let pattern3 = #"__NEXT_DATA__\s*=\s*(\{[\s\S]*?\})\s*[;<]"#
    if let result = firstCapture(in: html, pattern: pattern3) {
        return result
    }
    
    // Стратегия 4: JSON-escaped или URL-encoded версия
    let decoded = html.removingPercentEncoding ?? html
    if decoded != html {
        // Пробуем все паттерны на декодированной версии
        if let result = firstCapture(in: decoded, pattern: pattern1) {
            return result
        }
        if let result = firstCapture(in: decoded, pattern: pattern2) {
            return result
        }
        if let result = firstCapture(in: decoded, pattern: pattern3) {
            return result
        }
    }
    
    // Стратегия 5: Ищем просто большой JSON объект с ключом "props" (характерно для Next.js)
    // Это менее надёжно, но может помочь если __NEXT_DATA__ обёрнут по-другому
    let pattern5 = #"<script[^>]*>\s*(\{[^{}]*"props"[\s\S]{100,})\s*</script>"#
    if let result = firstCapture(in: html, pattern: pattern5) {
        // Проверяем, что это похоже на __NEXT_DATA__ (содержит pageProps или buildId)
        if result.contains("pageProps") || result.contains("buildId") || result.contains("__NEXT_DATA__") {
            return result
        }
    }
    
    // Стратегия 5.1: Ищем в URL-encoded или HTML-encoded виде
    let decodedHtml = html.removingPercentEncoding ?? html
    if decodedHtml != html {
        // Пробуем все паттерны на декодированной версии
        if let result = firstCapture(in: decodedHtml, pattern: pattern1) {
            return result
        }
        if let result = firstCapture(in: decodedHtml, pattern: pattern2) {
            return result
        }
        if let result = firstCapture(in: decodedHtml, pattern: pattern3) {
            return result
        }
    }
    
    // Стратегия 5.2: Ищем в HTML entities (&#x5f; = _, &#x4e; = N, и т.д.)
    // Конвертируем HTML entities обратно в нормальный текст
    let htmlEntitiesPattern = #"&#x([0-9a-fA-F]+);"#
    if let regex = try? NSRegularExpression(pattern: htmlEntitiesPattern, options: []),
       regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) != nil {
        // Пробуем декодировать HTML entities и искать в декодированной версии
        if let decodedMatch = try? NSRegularExpression(pattern: #"&#x5f;&#x5f;NEXT_DATA&#x5f;&#x5f;"#, options: []).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
            // Нашли закодированный __NEXT_DATA__, пробуем найти JSON после него
            let afterMatch = String(html[html.index(html.startIndex, offsetBy: decodedMatch.range.upperBound)...])
            if let jsonStart = afterMatch.range(of: "{") {
                // Пытаемся найти закрывающую скобку
                var braceCount = 1
                var endIndex = jsonStart.upperBound
                while braceCount > 0 && endIndex < afterMatch.endIndex {
                    let char = afterMatch[endIndex]
                    if char == "{" {
                        braceCount += 1
                    } else if char == "}" {
                        braceCount -= 1
                    }
                    endIndex = afterMatch.index(endIndex, offsetBy: 1)
                }
                if braceCount == 0 {
                    let jsonStr = String(afterMatch[jsonStart.lowerBound..<endIndex])
                    if jsonStr.contains("pageProps") || jsonStr.contains("downloadable_url") || jsonStr.contains("encodings") {
                        return jsonStr
                    }
                }
            }
        }
    }
    
    // Стратегия 6: Ищем очень большой JSON объект (может быть __NEXT_DATA__ без явного тега)
    // Ищем объекты размером больше 1000 символов, содержащие "downloadable_url" или "encodings"
    let largeJsonPattern = #"(\{[^{}]*"(?:downloadable_url|encodings|pageProps)"[\s\S]{1000,})"#
    if let regex = try? NSRegularExpression(pattern: largeJsonPattern, options: [.dotMatchesLineSeparators]),
       let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
       match.numberOfRanges > 1,
       let range = Range(match.range(at: 1), in: html) {
        var jsonStr = String(html[range])
        // Пытаемся найти закрывающую скобку
        var braceCount = 1
        var endIndex = range.upperBound
        while braceCount > 0 && endIndex < html.endIndex {
            let char = html[endIndex]
            if char == "{" {
                braceCount += 1
            } else if char == "}" {
                braceCount -= 1
            }
            endIndex = html.index(endIndex, offsetBy: 1)
        }
        if braceCount == 0 {
            jsonStr = String(html[range.lowerBound..<endIndex])
            // Проверяем, что это похоже на __NEXT_DATA__
            if jsonStr.contains("pageProps") || jsonStr.contains("downloadable_url") || jsonStr.contains("encodings") {
                return jsonStr
            }
        }
    }
    
    return nil
}

// Ищет vg-assets ссылки (могут быть в разных форматах)
// ВАЖНО: vg-assets ссылки часто ведут к оригиналу без ватермарки!
// ВАЖНО: vg-assets могут быть как /vg-assets/, так и /az/vg-assets/
private func extractVgAssetsUrl(from html: String, logger: Logger?) -> String? {
    // 1) Прямая ссылка vg-assets с src.mp4 (высший приоритет) - учитываем и /az/vg-assets/
    let directVgPattern = #"https://videos\.openai\.com(/az)?/vg-assets/[^\s"'<>]+?src\.mp4[^\s"'<>]*"#
    if let found = firstMatch(in: html, pattern: directVgPattern) {
        logger?.info("✅ Found vg-assets with src.mp4: \(found.prefix(200))...")
        return decodePotentiallyEncodedURL(found)
    }
    
    // 2) Percent-encoded vg-assets - учитываем и /az/vg-assets/
    let percentVgPattern = #"https%3A%2F%2Fvideos\.openai\.com(%2Faz)?%2Fvg-assets%2F[^&"'<>\s]+src\.mp4[^&"'<>\s]*"#
    if let found = firstMatch(in: html, pattern: percentVgPattern) {
        let decoded = decodePotentiallyEncodedURL(found)
        if decoded.contains("src.mp4") {
            logger?.info("✅ Found percent-encoded vg-assets with src.mp4: \(decoded.prefix(200))...")
            return decoded
        }
    }
    
    // 3) JSON-escaped vg-assets - учитываем и /az/vg-assets/
    let jsonVgPattern = #"https:\/\/videos\.openai\.com(\/az)?\/vg-assets\/[^"]+src\.mp4[^"]*"#
    if let found = firstMatch(in: html, pattern: jsonVgPattern) {
        let decoded = decodePotentiallyEncodedURL(found)
        if decoded.contains("src.mp4") {
            logger?.info("✅ Found JSON-escaped vg-assets with src.mp4: \(decoded.prefix(200))...")
            return decoded
        }
    }
    
    // 4) Собираем ВСЕ vg-assets ссылки и выбираем лучшую (не только с src.mp4)
    // ВАЖНО: учитываем и /az/vg-assets/ тоже!
    let anyVgPattern = #"https://videos\.openai\.com(/az)?/vg-assets/[^\s"'<>\\]+"#
    let candidates = allMatches(in: html, pattern: anyVgPattern)
    if candidates.isEmpty == false {
        let decoded = candidates.map { decodePotentiallyEncodedURL($0) }
        logger?.info("🔍 Found \(decoded.count) vg-assets candidates: \(decoded.prefix(5).map { $0.prefix(150) }.joined(separator: " | "))")
        // Приоритет: src.mp4 > .mp4 > m3u8 > любые другие vg-assets (но не thumbnail/jpeg)
        if let best = decoded.first(where: { 
            $0.contains("src.mp4") && 
            !$0.contains("thumbnail") && 
            !$0.contains(".jpeg") && 
            !$0.contains(".jpg")
        }) { 
            logger?.info("✅ Found vg-assets with src.mp4 (from all candidates): \(best.prefix(200))...")
            return best 
        }
        if let mp4 = decoded.first(where: { 
            $0.contains(".mp4") && 
            !$0.contains("thumbnail") && 
            !$0.contains(".jpeg") && 
            !$0.contains(".jpg")
        }) { 
            logger?.info("✅ Found vg-assets with .mp4: \(mp4.prefix(200))...")
            return mp4 
        }
        if let m3u8 = decoded.first(where: { 
            $0.contains("m3u8") && 
            !$0.contains("thumbnail")
        }) { 
            logger?.info("✅ Found vg-assets with m3u8: \(m3u8.prefix(200))...")
            return m3u8 
        }
        // Последний вариант: любые vg-assets (но не thumbnail/jpeg)
        if let anyVg = decoded.first(where: { 
            !$0.contains("thumbnail") && 
            !$0.contains(".jpeg") && 
            !$0.contains(".jpg") &&
            !$0.contains(".png")
        }) {
            logger?.info("✅ Found vg-assets (any video): \(anyVg.prefix(200))...")
            return anyVg
        }
        
        // ПОСЛЕДНЯЯ ПОПЫТКА: если все vg-assets ссылки - thumbnail, попробуем заменить #thumbnail на #src.mp4
        // ВАЖНО: нужно сохранить ВСЕ параметры запроса после ?
        if let thumbnailVg = decoded.first(where: { 
            $0.contains("vg-assets") && 
            ($0.contains("#thumbnail") || $0.contains("thumbnail"))
        }) {
            // Разделяем URL на путь и параметры запроса
            let urlParts = thumbnailVg.split(separator: "?", maxSplits: 1)
            var pathPart = String(urlParts[0])
            let queryPart = urlParts.count > 1 ? "?" + String(urlParts[1]) : ""
            
            // Вариант 1: заменить #thumbnail.jpeg на #src.mp4
            if pathPart.contains("#thumbnail.jpeg") {
                pathPart = pathPart.replacingOccurrences(of: "#thumbnail.jpeg", with: "#src.mp4")
                let modifiedUrl = pathPart + queryPart
                logger?.info("🔧 Attempting to modify vg-assets URL: replaced #thumbnail.jpeg with #src.mp4 (preserving all query params)")
                logger?.info("🔧 Modified URL: \(modifiedUrl.prefix(200))...")
                return modifiedUrl
            }
            
            // Вариант 2: заменить #thumbnail на #src.mp4
            if pathPart.contains("#thumbnail") {
                pathPart = pathPart.replacingOccurrences(of: "#thumbnail", with: "#src.mp4")
                let modifiedUrl = pathPart + queryPart
                logger?.info("🔧 Attempting to modify vg-assets URL: replaced #thumbnail with #src.mp4 (preserving all query params)")
                logger?.info("🔧 Modified URL: \(modifiedUrl.prefix(200))...")
                return modifiedUrl
            }
            
            // Вариант 3: заменить thumbnail.jpeg на src.mp4 в любом месте
            if pathPart.contains("thumbnail.jpeg") {
                pathPart = pathPart.replacingOccurrences(of: "thumbnail.jpeg", with: "src.mp4")
                let modifiedUrl = pathPart + queryPart
                logger?.info("🔧 Attempting to modify vg-assets URL: replaced thumbnail.jpeg with src.mp4 (preserving all query params)")
                logger?.info("🔧 Modified URL: \(modifiedUrl.prefix(200))...")
                return modifiedUrl
            }
            
            // Вариант 4: удалить #thumbnail часть, оставив #file_ и добавив #src.mp4
            if let fileIndex = pathPart.range(of: "#file_") {
                let beforeFile = String(pathPart[..<fileIndex.upperBound])
                // Добавляем src.mp4 после #file_...
                if let hashAfterFile = pathPart[fileIndex.upperBound...].firstIndex(of: "#") {
                    // Есть еще один # после #file_, заменяем часть после него
                    let afterFileHash = String(pathPart[..<hashAfterFile])
                    let modifiedUrl = afterFileHash + "#src.mp4" + queryPart
                    logger?.info("🔧 Attempting to modify vg-assets URL: removed thumbnail part, added #src.mp4 (preserving all query params)")
                    logger?.info("🔧 Modified URL: \(modifiedUrl.prefix(200))...")
                    return modifiedUrl
                } else {
                    // Нет # после #file_, просто добавляем #src.mp4
                    let modifiedUrl = beforeFile + "file_" + String(pathPart[fileIndex.upperBound...]) + "#src.mp4" + queryPart
                    logger?.info("🔧 Attempting to modify vg-assets URL: added #src.mp4 (preserving all query params)")
                    logger?.info("🔧 Modified URL: \(modifiedUrl.prefix(200))...")
                    return modifiedUrl
                }
            }
        }
        
        logger?.debug("vg-assets candidates (all): \(decoded.prefix(5).joined(separator: ", "))")
    }
    
    return nil
}

// Парсим JSON и ищем любые ссылки на videos.openai.com; возвращаем лучший mp4/hls
private func extractFromNextData(_ jsonString: String, logger: Logger?) -> String? {
    guard let data = jsonString.data(using: .utf8) else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
    var collected: [String] = []
    var priorityUrls: [String] = [] // Приоритетные ссылки (vg-assets, src.mp4)
    var downloadableUrl: String? = nil // downloadable_url - самый высокий приоритет
    var encodingSourcePath: String? = nil // encodings.source.path - высокий приоритет

    func walk(_ value: Any, path: String = "") {
        if let dict = value as? [String: Any] {
            // Проверяем ключи, которые могут содержать ссылки на видео
            for (key, v) in dict {
                let currentPath = path.isEmpty ? key : "\(path).\(key)"
                // Приоритетные ключи для видео
                let keyLower = key.lowercased()
                
                // Специальная обработка для encodings - там может быть source (без ватермарки) и source_wm (с ватермаркой)
                if keyLower == "encodings" {
                    if let encodingsDict = v as? [String: Any] {
                        logger?.debug("Found encodings dict at path '\(currentPath)', keys: \(encodingsDict.keys.joined(separator: ", "))")
                        
                        // Ищем source.path (оригинал без ватермарки) - высший приоритет
                        if let source = encodingsDict["source"] as? [String: Any] {
                            logger?.debug("Found encodings.source at path '\(currentPath)', keys: \(source.keys.joined(separator: ", "))")
                            if let path = source["path"] as? String,
                               path.contains("videos.openai.com") && !path.contains("sora.chatgpt.com") {
                                let decoded = decodePotentiallyEncodedURL(path)
                                if !decoded.contains("thumbnail") && !decoded.contains(".jpeg") && !decoded.contains(".jpg") && !decoded.contains(".png") {
                                    encodingSourcePath = decoded // Сохраняем отдельно для самого высокого приоритета
                                    priorityUrls.insert(decoded, at: 0) // Также добавляем в priorityUrls
                                    logger?.info("✅ Found encodings.source.path (original without watermark) at path '\(currentPath)': \(decoded)")
                                }
                            }
                        }
                        // source_wm - с ватермаркой, но тоже может быть полезен
                        if let sourceWm = encodingsDict["source_wm"] as? [String: Any] {
                            if let path = sourceWm["path"] as? String,
                               path.contains("videos.openai.com") && !path.contains("sora.chatgpt.com") {
                                let decoded = decodePotentiallyEncodedURL(path)
                                if !decoded.contains("thumbnail") && !decoded.contains(".jpeg") && !decoded.contains(".jpg") && !decoded.contains(".png") {
                                    collected.append(decoded)
                                    logger?.debug("Found encodings.source_wm.path (with watermark) at path '\(currentPath)': \(decoded)")
                                }
                            }
                        }
                    }
                }
                
                if keyLower == "downloadable_url" || keyLower == "downloadableurl" {
                    // downloadable_url часто ведёт к оригиналу без ватермарки
                    if let s = v as? String, s.contains("videos.openai.com") && !s.contains("sora.chatgpt.com") {
                        let decoded = decodePotentiallyEncodedURL(s)
                        // Проверяем, что это не thumbnail
                        if !decoded.contains("thumbnail") && !decoded.contains(".jpeg") && !decoded.contains(".jpg") && !decoded.contains(".png") {
                            downloadableUrl = decoded // Сохраняем отдельно для самого высокого приоритета
                            priorityUrls.insert(decoded, at: 0) // Также добавляем в priorityUrls
                            logger?.info("✅ Found downloadable_url at path '\(currentPath)': \(decoded)")
                        }
                    }
                } else if ["videoUrl", "video_url", "source", "url", "src", "video", "mp4", "mediaUrl", "media_url"].contains(keyLower) {
                    if let s = v as? String, s.contains("videos.openai.com") {
                        let decoded = decodePotentiallyEncodedURL(s)
                        if decoded.contains("vg-assets") || decoded.contains("src.mp4") {
                            priorityUrls.append(decoded)
                        } else {
                            collected.append(decoded)
                        }
                    }
                }
                walk(v, path: currentPath)
            }
        } else if let arr = value as? [Any] {
            for (idx, v) in arr.enumerated() {
                walk(v, path: "\(path)[\(idx)]")
            }
        } else if let s = value as? String {
            // Исключаем ссылки на sora.chatgpt.com - нам нужны только videos.openai.com
            if s.contains("videos.openai.com") && !s.contains("sora.chatgpt.com") {
                let decoded = decodePotentiallyEncodedURL(s)
                // Фильтруем thumbnail и другие не-видео
                if !decoded.contains("thumbnail") && !decoded.contains(".jpeg") && !decoded.contains(".jpg") && !decoded.contains(".png") {
                    if decoded.contains("vg-assets") || decoded.contains("src.mp4") {
                        priorityUrls.append(decoded)
                    } else {
                        collected.append(decoded)
                    }
                }
            }
        }
    }
    walk(obj)
    
    logger?.info("extractFromNextData: found \(priorityUrls.count) priority URLs, \(collected.count) collected URLs")
    if priorityUrls.isEmpty == false {
        logger?.info("Priority URLs: \(priorityUrls.prefix(5).joined(separator: " | "))")
    }
    
    // САМЫЙ ВЫСОКИЙ ПРИОРИТЕТ: downloadable_url и encodings.source.path (они часто ведут к оригиналу без ватермарки)
    if let downloadable = downloadableUrl {
        logger?.info("🎯 Using downloadable_url (highest priority): \(downloadable)")
        return downloadable
    }
    if let encoding = encodingSourcePath {
        logger?.info("🎯 Using encodings.source.path (highest priority): \(encoding)")
        return encoding
    }

    // Затем проверяем приоритетные
    if priorityUrls.isEmpty == false {
        // Самый высокий приоритет - /az/files/{id}/raw БЕЗ /drvs/ (оригинал без ватермарки)
        // Сортируем: сначала /az/files/{uuid}/raw без /drvs/, потом остальные
        let sorted = priorityUrls.sorted { url1, url2 in
            let isDirectRaw1 = url1.contains("/az/files/") && url1.contains("/raw") && !url1.contains("/drvs/")
            let isDirectRaw2 = url2.contains("/az/files/") && url2.contains("/raw") && !url2.contains("/drvs/")
            if isDirectRaw1 && !isDirectRaw2 { return true }
            if !isDirectRaw1 && isDirectRaw2 { return false }
            return url1 < url2
        }
        
        // Для /az/files/{uuid}/raw проверяем наличие всех SAS-параметров
        if let directRaw = sorted.first(where: { 
            $0.contains("/az/files/") && 
            $0.contains("/raw") && 
            !$0.contains("/drvs/") &&
            ($0.contains("?se=") || $0.contains("&se=")) && 
            ($0.contains("?sp=") || $0.contains("&sp=")) && 
            ($0.contains("?sv=") || $0.contains("&sv=")) && 
            ($0.contains("?sr=") || $0.contains("&sr=")) && 
            ($0.contains("?sig=") || $0.contains("&sig=")) && 
            ($0.contains("?ac=") || $0.contains("&ac="))
        }) {
            logger?.info("Found validated direct /az/files/{id}/raw from priorityUrls (original without watermark): \(directRaw)")
            return directRaw
        }
        
        // Для других типов ссылок валидация не нужна
        if let best = sorted.first(where: { $0.contains("vg-assets") && $0.contains("src.mp4") }) { return best }
        if let vg = sorted.first(where: { $0.contains("vg-assets") && $0.contains("/videos/") }) { return vg }
        if let vgAny = sorted.first(where: { $0.contains("vg-assets") }) { return vgAny }
        if let src = sorted.first(where: { $0.contains("src.mp4") }) { return src }
        // Если ничего не подошло, возвращаем первую из приоритетных (но не /az/files/{uuid}/raw без валидации)
        if let first = sorted.first, !(first.contains("/az/files/") && first.contains("/raw") && !first.contains("/drvs/")) {
            logger?.info("Using first priority URL: \(first)")
            return first
        }
    }

    // Затем обычные
    if collected.isEmpty == false {
        // Самый высокий приоритет - /az/files/{id}/raw БЕЗ /drvs/ (оригинал без ватермарки)
        // Но только если есть все SAS-параметры
        if let directRaw = collected.first(where: { 
            $0.contains("/az/files/") && 
            $0.contains("/raw") && 
            !$0.contains("/drvs/") &&
            ($0.contains("?se=") || $0.contains("&se=")) && 
            ($0.contains("?sp=") || $0.contains("&sp=")) && 
            ($0.contains("?sv=") || $0.contains("&sv=")) && 
            ($0.contains("?sr=") || $0.contains("&sr=")) && 
            ($0.contains("?sig=") || $0.contains("&sig=")) && 
            ($0.contains("?ac=") || $0.contains("&ac="))
        }) {
            logger?.info("Found validated direct /az/files/{id}/raw from collected (original without watermark)")
            return directRaw
        }
        if let best = collected.first(where: { $0.contains("src.mp4") }) { return best }
        if let vg = collected.first(where: { $0.contains("vg-assets") && $0.contains("/videos/") }) { return vg }
        if let vgAny = collected.first(where: { $0.contains("vg-assets") }) { return vgAny }
        if let mp4 = collected.first(where: { $0.contains(".mp4") }) { return mp4 }
        if let hls = collected.first(where: { $0.contains("m3u8") }) { return hls }
        logger?.debug("NEXT_DATA candidates: \(collected.prefix(3).joined(separator: " | "))")
    }
    return nil
}

private func firstMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range), let r = Range(match.range, in: text) else {
        return nil
    }
    return String(text[r])
}

private func firstCapture(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1,
          let r = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[r])
}

private func allMatches(in text: String, pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = regex.matches(in: text, options: [], range: range)
    return matches.compactMap { m in
        guard let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }
}

// Извлекает UUID из JSON данных (ищет в ключах типа fileId, id, uuid, videoId и т.д.)
private func extractUUIDFromJSON(_ jsonString: String, logger: Logger?) -> String? {
    guard let data = jsonString.data(using: .utf8) else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
    
    var candidateUUIDs: [String] = []
    var priorityUUIDs: [String] = [] // UUID из приоритетных ключей
    
    func walk(_ value: Any, path: String = "") {
        if let dict = value as? [String: Any] {
            for (key, v) in dict {
                let currentPath = path.isEmpty ? key : "\(path).\(key)"
                // Приоритетные ключи для UUID файла
                if ["fileId", "file_id", "id", "uuid", "videoId", "video_id", "assetId", "asset_id", "fileUuid", "file_uuid", "mediaId", "media_id", "contentId", "content_id"].contains(key.lowercased()) {
                    if let s = v as? String, isValidUUID(s) {
                        priorityUUIDs.append(s)
                        logger?.debug("Found UUID candidate in key '\(key)' at path '\(currentPath)': \(s)")
                    }
                }
                walk(v, path: currentPath)
            }
        } else if let arr = value as? [Any] {
            for (idx, v) in arr.enumerated() {
                walk(v, path: "\(path)[\(idx)]")
            }
        } else if let s = value as? String {
            // Ищем UUID в строках (могут быть в URL или как значения)
            if isValidUUID(s) {
                candidateUUIDs.append(s)
            }
        }
    }
    walk(obj)
    
    // Сначала проверяем приоритетные UUID
    if priorityUUIDs.isEmpty == false {
        // Выбираем UUID, который начинается с "00000000" (это часто формат для файлов)
        if let prefixed = priorityUUIDs.first(where: { $0.hasPrefix("00000000-") }) {
            logger?.info("Selected priority UUID with 00000000- prefix: \(prefixed)")
            return prefixed
        }
        // Иначе первый из приоритетных
        logger?.info("Selected first priority UUID: \(priorityUUIDs.first!)")
        return priorityUUIDs.first
    }
    
    // Затем проверяем все остальные
    if candidateUUIDs.isEmpty == false {
        // Выбираем UUID, который начинается с "00000000"
        if let prefixed = candidateUUIDs.first(where: { $0.hasPrefix("00000000-") }) {
            logger?.info("Selected UUID with 00000000- prefix from all candidates: \(prefixed)")
            return prefixed
        }
        logger?.debug("Selected first UUID from all candidates: \(candidateUUIDs.first!)")
        return candidateUUIDs.first
    }
    
    return nil
}

// Проверяет, является ли строка валидным UUID
private func isValidUUID(_ s: String) -> Bool {
    let pattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
    return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive).firstMatch(in: s, options: [], range: NSRange(s.startIndex..<s.endIndex, in: s))) != nil
}

// Извлекает все UUID из текста (для отладки)
// Ищет UUID в разных форматах: обычный, percent-encoded, JSON-escaped
private func extractAllUUIDs(from text: String) -> [String] {
    var foundUUIDs: Set<String> = []
    
    // 1. Обычный формат UUID
    let pattern = #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        for match in matches {
            if let r = Range(match.range, in: text) {
                foundUUIDs.insert(String(text[r]))
            }
        }
    }
    
    // 2. Percent-encoded формат (например, %30%30%30%30%30%30%30%30-%33%63%38%63)
    // Ищем паттерн вида: %30%30%30%30%30%30%30%30-%33%63%38%63-...
    let percentPattern = #"(?:%[0-9a-fA-F]{2}){8}-(?:%[0-9a-fA-F]{2}){4}-(?:%[0-9a-fA-F]{2}){4}-(?:%[0-9a-fA-F]{2}){4}-(?:%[0-9a-fA-F]{2}){12}"#
    if let regex = try? NSRegularExpression(pattern: percentPattern, options: []) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        for match in matches {
            if let r = Range(match.range, in: text) {
                let encoded = String(text[r])
                if let decoded = encoded.removingPercentEncoding, isValidUUID(decoded) {
                    foundUUIDs.insert(decoded)
                }
            }
        }
    }
    
    // 3. JSON-escaped формат (например, \u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030-\u0033\u0063\u0038\u0063)
    // Это сложнее, но можем попробовать декодировать всю строку и искать UUID
    
    return Array(foundUUIDs)
}

// Извлекает ВСЕ ссылки videos.openai.com из HTML с разными вариантами кодирования
private func extractAllVideoUrls(from html: String) -> [String] {
    var allUrls: Set<String> = []
    
    // 1. Прямые ссылки: https://videos.openai.com/...
    // Улучшенный паттерн: не останавливаемся на закрывающей скобке, если она часть URL-параметра
    // Ищем до пробела, двойной кавычки, одинарной кавычки, < или >, но не на )
    let directPattern = #"https://videos\.openai\.com[^\s"'<>]+"#
    if let regex = try? NSRegularExpression(pattern: directPattern, options: []) {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        for match in matches {
            if let r = Range(match.range, in: html) {
                let url = String(html[r])
                let decoded = decodePotentiallyEncodedURL(url)
                if decoded.contains("videos.openai.com") {
                    allUrls.insert(decoded)
                }
            }
        }
    }
    
    // 2. JSON-escaped: https:\/\/videos.openai.com...
    // ВАЖНО: НЕ останавливаемся на пробелах внутри URL - добавляем \s в исключения
    let jsonEscapedPattern = #"https:\\?/\\?/videos\.openai\.com[^"\\\s]+"#
    if let regex = try? NSRegularExpression(pattern: jsonEscapedPattern, options: []) {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        for match in matches {
            if let r = Range(match.range, in: html) {
                let url = String(html[r])
                let decoded = decodePotentiallyEncodedURL(url)
                if decoded.contains("videos.openai.com") {
                    allUrls.insert(decoded)
                }
            }
        }
    }
    
    // 3. Percent-encoded: https%3A%2F%2Fvideos.openai.com...
    let percentPattern = #"https%3A%2F%2Fvideos\.openai\.com[^&"'<>\s]+"#
    if let regex = try? NSRegularExpression(pattern: percentPattern, options: []) {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        for match in matches {
            if let r = Range(match.range, in: html) {
                let url = String(html[r])
                let decoded = decodePotentiallyEncodedURL(url)
                if decoded.contains("videos.openai.com") {
                    allUrls.insert(decoded)
                }
            }
        }
    }
    
    return Array(allUrls)
}

// Извлекает UUID из URL вида /az/files/{hash}_{uuid}/drvs/...
private func extractUUIDFromDrvsUrl(_ url: String) -> String? {
    // Паттерн: /az/files/{hash}_{uuid}/drvs/
    let pattern = #"/az/files/[^/]+_([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/drvs/"#
    return firstCapture(in: url, pattern: pattern)
}

// Извлекает UUID из прямой ссылки вида /az/files/{uuid}/raw
private func extractUUIDFromDirectRaw(_ url: String) -> String? {
    // Паттерн: /az/files/{uuid}/raw (может быть percent-encoded как %2Fraw)
    let pattern1 = #"/az/files/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/raw"#
    if let uuid = firstCapture(in: url, pattern: pattern1) {
        return uuid
    }
    // Percent-encoded вариант
    let pattern2 = #"/az/files/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})%2Fraw"#
    return firstCapture(in: url, pattern: pattern2)
}

// Извлекает query параметры из URL
private func extractParamsFromUrl(_ url: String) -> String? {
    guard let queryRange = url.range(of: "?") else { return nil }
    let queryString = String(url[queryRange.upperBound...])
    return queryString.isEmpty ? nil : queryString
}

// Извлекает task_id из HTML/JSON (формат: task_01k7aaa5ryfngt37ys2fe11jg7)
private func extractTaskId(from text: String) -> String? {
    let pattern = #"task_[a-z0-9]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
          let r = Range(match.range, in: text) else { return nil }
    return String(text[r])
}

// Декодирует сочетания JSON-эскейпов, HTML-энкодинга и percent-encoding
private func decodePotentiallyEncodedURL(_ s: String) -> String {
    var result = s
    // Удаляем возможные завершающие кавычки/пробелы/обратные слэши
    result = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"\\")))
    // JSON escapes - декодируем все распространённые Unicode escape-последовательности
    result = result.replacingOccurrences(of: #"\u0026"#, with: "&")  // & - ВАЖНО для JSON-escaped параметров URL
    result = result.replacingOccurrences(of: #"\u002F"#, with: "/")  // /
    result = result.replacingOccurrences(of: #"\u003D"#, with: "=")  // =
    result = result.replacingOccurrences(of: #"\u003F"#, with: "?")   // ?
    result = result.replacingOccurrences(of: #"\/"#, with: "/")
    // HTML entities
    result = result.replacingOccurrences(of: "&amp;", with: "&")
    result = result.replacingOccurrences(of: "&quot;", with: "\"")
    // Percent-decoding (дважды на всякий случай)
    if let once = result.removingPercentEncoding { result = once }
    if let twice = result.removingPercentEncoding { result = twice }
    // Удаляем обратный слэш в конце (если остался после декодирования)
    if result.hasSuffix("\\") {
        result = String(result.dropLast())
    }
    return result
}

private func sendTelegramMessage(token: String, chatId: Int64, text: String, client: Client) async throws -> Bool {
    struct Payload: Content {
        let chat_id: Int64
        let text: String
        let disable_web_page_preview: Bool
    }
    let payload = Payload(chat_id: chatId, text: text, disable_web_page_preview: false)
    let url = "https://api.telegram.org/bot\(token)/sendMessage"
    let res = try await client.post(URI(string: url)) { req in
        try req.content.encode(payload, as: .json)
    }
    return res.status == .ok
}

