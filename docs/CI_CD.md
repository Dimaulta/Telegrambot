# CI/CD: автоматический деплой (сборка в GitHub, деплой на VPS)

## Как устроено

1. **Push в main** запускает workflow "Deploy to Production (Build in GHA)".
2. **Detect**: по SSH читается `.last_deploy_commit` с VPS, по diff с HEAD решается, какие сервисы пересобирать (или "none", или список, или "all").
3. **Build** (если не none): образы собираются **в GitHub Actions** (linux/amd64), пушатся в GitHub Container Registry (ghcr.io). Сборка идёт **последовательно**, чтобы не упираться в память раннера.
4. **Deploy** (если был build): на VPS выполняется git pull, docker login ghcr.io, docker compose pull, docker compose up -d, set-webhooks, запись нового коммита в `.last_deploy_commit`.
5. **Deploy-no-rebuild** (если services=none): на VPS только git pull и обновление `.last_deploy_commit` (образы не трогаем).

На VPS **никогда не запускается docker build**: только pull и up. Нагрузка по CPU/RAM от сборки на сервер не попадает.

---

## Что нужно один раз настроить

### 1. Секрет для pull образов с VPS

На VPS деплой делает `docker pull` из ghcr.io. Нужна авторизация:

- В GitHub: **Settings → Developer settings → Personal access tokens** создать токен с правом **read:packages**.
- В репозитории: **Settings → Secrets and variables → Actions** добавить секрет **GHCR_TOKEN** (значение — этот токен).

В workflow на VPS передаётся `GHCR_TOKEN`, и в шаге deploy выполняется `docker login ghcr.io -u <owner> --password-stdin`.

### 2. Имя владельца репозитория и образы

В `docker-compose.prod.yml` образы заданы как `ghcr.io/dimaulta/telegrambot-<service>:latest`. Если твой GitHub-аккаунт не `dimaulta`, замени в compose `dimaulta` на свой логин (нижний регистр).

### 3. Первый запуск после перехода на ghcr.io

После первого пуша с новым workflow и compose:

- Detect увидит изменение `docker-compose.prod.yml` и выставит **rebuild all**.
- Build соберёт и запушит все 7 образов в ghcr.io (последовательно, около 60–90 минут).
- Deploy сделает на VPS pull и up.

До этого образы в ghcr.io должны быть собраны этим же workflow (ничего вручную пушить не нужно). После первого успешного прогона дальше будут пересобираться только изменённые сервисы.

---

## Подводные камни и что делать

| Ситуация | Причина | Что делать |
|----------|--------|------------|
| Job "detect" падает по SSH | Таймаут/сеть, неверный ключ или хост | Проверить VPS_SSH_KEY, VPS_HOST, VPS_SSH_PORT, доступность VPS из интернета. При временных сбоях перезапустить workflow. |
| `.last_deploy_commit` нет или битый коммит | Первый деплой или старый коммит стёрт | Workflow подставляет HEAD~15 и при необходимости пересобирает все сервисы. После успешного деплоя файл создаётся/обновляется. |
| Job "build" падает (OOM, timeout) | Раннеру не хватает памяти или сборка дольше 120 мин | Сборка уже последовательная. Если падает один сервис — перезапустить только job "build". Таймаут 120 мин; при стабильном падении одного продукта смотреть логи сборки. |
| Job "deploy" падает на docker login | Нет или неверный GHCR_TOKEN | Добавить/обновить секрет GHCR_TOKEN (PAT с read:packages). Убедиться, что пакеты в ghcr.io доступны этому токену (или сделать пакеты публичными). |
| Job "deploy" падает на pull | Образ не найден в ghcr.io | Убедиться, что build для этого сервиса прошёл и образ запушен. Проверить имя образа в compose (владелец, имя репозитория). |
| После деплоя боты не отвечают | Контейнеры не поднялись или упали | На VPS: `docker compose -f docker-compose.prod.yml ps` и `docker compose -f docker-compose.prod.yml logs --tail=50`. Проверить config/.env и webhooks (set-webhooks.sh). |
| Изменил только .github/ или docs/ | По логике detect это "ignored" | SERVICES=none, сборка не запускается, выполнится только deploy-no-rebuild (git pull + обновление .last_deploy_commit). Это ожидаемо. |
| Хочу пересобрать всё вручную | Нужны свежие образы всех сервисов | Временно изменить Dockerfile.prod или docker-compose.prod.yml и push (например, комментарий), либо вручную запустить workflow и при необходимости поправить detect так, чтобы вернулся "all". |

---

## Секреты репозитория (напоминание)

- **VPS_SSH_KEY** — приватный ключ для SSH на VPS.
- **VPS_HOST** — хост (IP или домен).
- **VPS_USER** — пользователь SSH (например, root).
- **VPS_SSH_PORT** — порт SSH (например, 22).
- **GHCR_TOKEN** — GitHub PAT с правом read:packages (для docker pull на VPS).

---

## Локальная разработка и сборка на VPS

- **Локально**: для тестов можно собирать образы как раньше: `docker compose -f docker-compose.prod.yml build <service>` (в compose сейчас только `image:`, но при необходимости можно временно вернуть `build:` в отдельном override).
- **На VPS без CI**: если нужно поднять сервер без GitHub (например, только pull уже собранных образов), на VPS должны быть `docker login ghcr.io` и `docker compose -f docker-compose.prod.yml pull && docker compose -f docker-compose.prod.yml up -d`. Образы должны быть уже в ghcr.io (собраны через workflow или вручную запушены).
