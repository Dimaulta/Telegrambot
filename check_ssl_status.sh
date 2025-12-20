#!/bin/bash

echo "═══════════════════════════════════════════════════════════════"
echo "🔍 ПРОВЕРКА DNS И SSL СЕРТИФИКАТОВ"
echo "═══════════════════════════════════════════════════════════════"
echo ""

echo "📡 Проверка DNS с публичных серверов:"
echo ""

GOOGLE_DNS=$(dig @8.8.8.8 nowbots.ru A +short 2>/dev/null)
CLOUDFLARE_DNS=$(dig @1.1.1.1 nowbots.ru A +short 2>/dev/null)
EXPECTED_IP="85.208.110.226"

echo "  Google DNS (8.8.8.8):     ${GOOGLE_DNS:-❌ НЕ РАЗРЕШАЕТСЯ}"
echo "  Cloudflare DNS (1.1.1.1): ${CLOUDFLARE_DNS:-❌ НЕ РАЗРЕШАЕТСЯ}"
echo "  Ожидаемый IP:             ${EXPECTED_IP}"
echo ""

if [ "$GOOGLE_DNS" = "$EXPECTED_IP" ] && [ "$CLOUDFLARE_DNS" = "$EXPECTED_IP" ]; then
    echo "✅ DNS распространился глобально!"
    DNS_OK=true
else
    echo "⏳ DNS еще не распространился, нужно подождать..."
    DNS_OK=false
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🔒 Проверка SSL сертификата:"
echo "═══════════════════════════════════════════════════════════════"
echo ""

CERT_CN=$(echo | openssl s_client -connect nowbots.ru:443 -servername nowbots.ru 2>/dev/null | grep -oP 'CN = \K[^,]+' | head -1)

if [ -z "$CERT_CN" ]; then
    echo "  ❌ Не удалось проверить сертификат"
elif [ "$CERT_CN" = "nowbots.ru" ]; then
    echo "  ✅ Сертификат Let's Encrypt получен! (CN = $CERT_CN)"
    CERT_OK=true
elif [ "$CERT_CN" = "TRAEFIK DEFAULT CERT" ]; then
    echo "  ⏳ Используется самоподписанный сертификат (CN = $CERT_CN)"
    echo "  ⏳ Ожидание получения сертификата от Let's Encrypt..."
    CERT_OK=false
else
    echo "  ⚠️  Неизвестный сертификат (CN = $CERT_CN)"
    CERT_OK=false
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📋 Последние ошибки Traefik (ACME):"
echo "═══════════════════════════════════════════════════════════════"
echo ""

docker logs telegrambot_traefik 2>&1 | grep -i "acme.*error\|unable.*certificate" | tail -3 || echo "  ✅ Ошибок не найдено"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📊 ИТОГОВЫЙ СТАТУС:"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [ "$DNS_OK" = true ] && [ "$CERT_OK" = true ]; then
    echo "  🎉 ВСЁ ГОТОВО! Можно устанавливать webhooks!"
elif [ "$DNS_OK" = true ] && [ "$CERT_OK" = false ]; then
    echo "  ⏳ DNS готов, но сертификат еще не получен"
    echo "  ⏳ Traefik автоматически получит сертификат в ближайшее время"
elif [ "$DNS_OK" = false ]; then
    echo "  ⏳ Ожидание распространения DNS..."
    echo "  ⏳ Проверь снова через 10-15 минут"
fi

echo ""

