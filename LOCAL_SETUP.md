# СОВА — локальный запуск

Схема локальной среды: инфраструктура (PostgreSQL, Redis, Gotenberg, Keycloak +
его PostgreSQL) работает в Docker из `sova-infra/compose.local.yml`, а backend
(Django) и frontend (Next.js) запускаются нативно и ходят в контейнеры через
`127.0.0.1`.

```
Браузер → http://localhost:3000 (Next.js, нативно)
             │  /api/* проксируется в
             ▼
          http://localhost:8000 (Django, нативно)
             │
             ├─→ localhost:5432  PostgreSQL     (docker)
             ├─→ localhost:6379  Redis          (docker)
             ├─→ localhost:3001  Gotenberg      (docker)
             └─→ localhost:8080  Keycloak       (docker)
                                  └─ PostgreSQL Keycloak (docker, порт не публикуется)
```

Порядок запуска: **инфраструктура → backend → frontend**.

---

## 0. Что должно быть установлено

| Инструмент | Версия | Где зафиксирована |
| --- | --- | --- |
| Docker + Docker Compose v2 | актуальная | — |
| Python | 3.13 | `sova-backend/.python-version` |
| Poetry | актуальная | — |
| Node.js | 24.19.0 (минимум 20.9.0) | `sova-frontend/.nvmrc`, `package.json` |
| pnpm | 11.19.0 | `sova-frontend/package.json` (через corepack) |

Структура каталогов:

```
sova/
├── sova-infra/      # docker-compose локальной инфраструктуры
├── sova-backend/    # Django + DRF
└── sova-frontend/   # Next.js
```

Все три — отдельные Git-репозитории, рабочая ветка `develop`.

---

## 1. Инфраструктура в Docker (`sova-infra`)

```bash
cd sova-infra

cp .env.local.example .env.local
chmod 600 .env.local
```

Заполните в `.env.local` четыре обязательных значения (без пробелов, `$` и `#`):

- `POSTGRES_PASSWORD` — пароль основной БД приложения;
- `KEYCLOAK_DB_PASSWORD` — пароль БД самого Keycloak;
- `KEYCLOAK_ADMIN_PASSWORD` — пароль bootstrap-админа Keycloak;
- `KEYCLOAK_CLIENT_SECRET` — секрет OIDC-клиента `sova-web`; ровно это значение
  импортируется в realm и позже должно совпасть с `sova-backend/.env`.

Генерация значений:

```bash
openssl rand -hex 24
```

Поднять сервисы:

```bash
docker compose --env-file .env.local -f compose.local.yml up -d
docker compose --env-file .env.local -f compose.local.yml ps
```

Если realm уже был создан до добавления темы входа, примените её один раз:

```bash
docker compose --env-file .env.local -f compose.local.yml exec keycloak \
  /opt/keycloak/configure-keycloak-theme.sh
```

Дождитесь статуса `healthy` у всех сервисов (Keycloak стартует дольше всех,
`start_period` 45 секунд).

Что поднимается и на каких портах (всё слушает только `127.0.0.1`):

| Сервис | Адрес | Переменная порта |
| --- | --- | --- |
| PostgreSQL приложения | `localhost:5432`, база `sova`, пользователь `sova` | `POSTGRES_HOST_PORT` |
| Redis | `localhost:6379` | `REDIS_HOST_PORT` |
| Gotenberg | `http://localhost:3001` | `GOTENBERG_HOST_PORT` |
| Keycloak | `http://localhost:8080` | `KEYCLOAK_HOST_PORT` |
| PostgreSQL Keycloak | не публикуется наружу | — |
| S3 (Garage), опционально | `http://localhost:3900` | `S3_HOST_PORT` |

Realm `sova` импортируется автоматически из `keycloak/sova-realm.json` при
первом старте: клиент `sova-web`, redirect URI
`http://localhost:3000/api/auth/oidc/callback/`.

Если порт занят другим проектом, поменяйте соответствующий `*_HOST_PORT` в
`.env.local` и синхронно поправьте `DATABASE_URL` / `REDIS_URL` /
`KEYCLOAK_PUBLIC_URL` в `sova-backend/.env`. Смена `KEYCLOAK_HOST_PORT`
автоматически меняет `KC_HOSTNAME`, а `FRONTEND_HOST_PORT` — `rootUrl` и
redirect URI клиента `sova-web` в импортируемом realm.

### 1а. Своё хранилище файлов (Garage), опционально

Нужно только если в `sova-backend/.env` включаете `STORAGE_BACKEND=s3` вместо
файловой системы. Сервис не входит в обычный `up -d` (у него профиль `s3`):

Сначала задайте в `sova-backend/.env`: `STORAGE_BACKEND=s3`,
`S3_ENDPOINT_URL=http://localhost:3900`, `S3_REGION=garage`, `S3_ACCESS_KEY_ID`,
`S3_SECRET_ACCESS_KEY` (любые значения — `s3-bootstrap.sh` заведёт под них ключ в Garage) и,
если нужно, `S3_MEDIA_BUCKET`/`S3_REPORTS_BUCKET`. Затем в `sova-infra/.env.local` — свои
`GARAGE_RPC_SECRET` и `GARAGE_ADMIN_TOKEN` (`openssl rand -hex 32` / `openssl rand -base64 32`).

```bash
docker compose --env-file .env.local -f compose.local.yml --profile s3 up -d --wait s3

# s3-bootstrap.sh настраивает Garage под S3_* из sova-backend/.env — их нужно
# экспортировать в текущий шелл перед вызовом (сам .env.local их не содержит).
set -a
source ../sova-backend/.env
set +a
./scripts/s3-bootstrap.sh docker compose --env-file .env.local -f compose.local.yml
```

`s3-bootstrap.sh` идемпотентен: создаёт layout, бакеты `S3_MEDIA_BUCKET`/`S3_REPORTS_BUCKET`
и ключ приложения из `S3_ACCESS_KEY_ID`/`S3_SECRET_ACCESS_KEY` — повторный запуск ничего не
дублирует.

---

## 2. Backend локально (`sova-backend`)

```bash
cd ../sova-backend

poetry install
cp .env.example .env
```

В `.env` подставьте значения, согласованные с `sova-infra/.env.local`:

```dotenv
DJANGO_SECRET_KEY=<любая случайная строка, например openssl rand -hex 32>
DATABASE_URL=postgresql://sova:<POSTGRES_PASSWORD>@localhost:5432/sova
REDIS_URL=redis://localhost:6379/0
CELERY_BROKER_URL=redis://localhost:6379/1
GOTENBERG_URL=http://localhost:3001
KEYCLOAK_CLIENT_SECRET=<то же значение, что в sova-infra/.env.local>
# Токен от @BotFather; оставьте пустым, если Telegram не нужен.
TELEGRAM_BOT_TOKEN=
# Необязательный отдельный HTTP(S) или SOCKS proxy URL для Telegram.
TELEGRAM_PROXY=
NOTIFICATION_HTTP_TIMEOUT=10
```

Остальное в `.env.example` уже настроено на локальную среду:
`APP_PUBLIC_URL=http://localhost:3000`, `KEYCLOAK_PUBLIC_URL` и
`KEYCLOAK_INTERNAL_URL` = `http://localhost:8080`, realm `sova`, клиент
`sova-web`. `STATIC_ROOT` / `MEDIA_ROOT` оставьте закомментированными — пути
`/app/*` существуют только внутри production-образа. SMTP пустой: письма
печатаются в консоль.

Файл читается через `source`, поэтому значения должны быть shell-safe — без
пробелов, `$` и `#` вне кавычек.

Запуск:

```bash
set -a
source .env
set +a

poetry run python manage.py migrate
poetry run python manage.py runserver
```

Экспорт отчётов выполняется асинхронно. После запуска Django откройте два
дополнительных терминала в `sova-backend`, загрузите в каждом переменные из
`.env` теми же командами `set -a; source .env; set +a` и запустите:

```bash
poetry run celery -A sova worker --loglevel=INFO
```

```bash
poetry run celery -A sova beat --loglevel=INFO
```

Worker и Django должны использовать один `REPORTS_STORAGE_ROOT` (по умолчанию
`./private/reports`); готовые файлы выдаются только через API.

Backend поднимется на `http://127.0.0.1:8000`. Проверка:

- health: `http://127.0.0.1:8000/api/health/` (проверяет БД и Redis);
- Swagger UI: `http://127.0.0.1:8000/api/docs/`;
- OpenAPI-схема: `http://127.0.0.1:8000/api/schema/`.

Суперпользователь для `/admin/` (аварийный доступ, не через OIDC):

```bash
poetry run python manage.py createsuperuser
```

### 2а. Telegram-уведомления локально, опционально

В локальной схеме Django и Celery запускаются нативно, поэтому Telegram
настраивается в `sova-backend/.env`, а не в `sova-infra/.env.local`.

1. Создайте бота через `@BotFather` командой `/newbot` и запишите выданный
   токен в `TELEGRAM_BOT_TOKEN` в `sova-backend/.env`. Токен — секрет: не
   добавляйте рабочий `.env` в Git и не указывайте токен в профиле пользователя.
2. Если Telegram доступен только через прокси, задайте в том же файле
   `TELEGRAM_PROXY`. Поддерживаются URL HTTP(S) и SOCKS-прокси, в том числе с
   авторизацией:

   ```dotenv
   TELEGRAM_PROXY=http://user:password@proxy.example:3128
   # либо с разрешением DNS-имени Telegram через SOCKS-прокси:
   TELEGRAM_PROXY=socks5h://127.0.0.1:1080
   ```

   Логин и пароль с символами `@`, `:`, `/`, `#` или `$` нужно URL-кодировать.
   Рабочий proxy URL — такой же секрет, как токен бота.
3. Перезапустите Django и Celery worker после изменения `.env`, предварительно
   снова загрузив переменные командами `set -a; source .env; set +a` в каждом
   терминале. Beat можно не перезапускать: Telegram-запросы выполняет worker или
   Django-процесс.
4. Пользователь должен открыть бота в Telegram и отправить ему `/start`: бот не
   может первым начать личный диалог.
5. Получите `chat_id` из обновлений бота. Следующий фрагмент передаёт тот же
   прокси в `curl`, если `TELEGRAM_PROXY` заполнен:

   ```bash
   cd sova-backend
   set -a
   source .env
   set +a
   CURL_PROXY_ARGS=()
   if [[ -n "${TELEGRAM_PROXY}" ]]; then
     CURL_PROXY_ARGS=(--proxy "${TELEGRAM_PROXY}")
   fi
   curl "${CURL_PROXY_ARGS[@]}" --fail --silent --show-error \
     "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates"
   ```

   В ответе найдите `result[].message.chat.id`. Для личного диалога это обычно
   положительное число; у группы ID обычно отрицательный. Если `result` пуст,
   отправьте боту ещё одно сообщение и повторите запрос.
6. Откройте `http://127.0.0.1:8000/admin/` → **Профили уведомлений**, создайте
   или откройте профиль нужного пользователя и внесите число в поле
   **Telegram chat ID**. Токен в это поле вводить не нужно.
7. В разделе **Настройки уведомлений** откройте нужный тип уведомления и
   проверьте флаги **Включено**, нужного получателя и канала **Telegram**.

Проверить токен и `chat_id` напрямую через Telegram Bot API можно так:

```bash
TELEGRAM_CHAT_ID=123456789
CURL_PROXY_ARGS=()
if [[ -n "${TELEGRAM_PROXY}" ]]; then
  CURL_PROXY_ARGS=(--proxy "${TELEGRAM_PROXY}")
fi
curl "${CURL_PROXY_ARGS[@]}" --fail --silent --show-error \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=Тестовое уведомление СОВА" \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
```

Успешный ответ содержит `"ok":true`. После этой проверки уведомления СОВА
будут отправляться этому пользователю при наступлении включённых событий.

> Быстрый запуск без Docker вообще: удалите/закомментируйте `DATABASE_URL` и
> `REDIS_URL` — development-конфигурация тогда использует SQLite и in-memory
> cache. Авторизация через Keycloak в этом режиме работать не будет.

---

## 3. Frontend локально (`sova-frontend`)

В новом терминале:

```bash
cd sova-frontend

nvm install        # поставит версию из .nvmrc
nvm use
corepack enable

cp .env.example .env.local
pnpm install
pnpm dev
```

Приложение: `http://localhost:3000`.

`.env.local` содержит единственную переменную:

```dotenv
API_PROXY_TARGET=http://localhost:8000
```

Браузер всегда обращается к относительному `/api`, Next.js в dev проксирует эти
запросы в Django (`next.config.ts`, rewrites). Это нужно, чтобы session- и
CSRF-cookie оставались same-origin.

---

## 4. Первый вход через Keycloak

1. Откройте Admin Console: `http://localhost:8080/` → Administration Console.
2. Войдите как `KEYCLOAK_ADMIN_USERNAME` / `KEYCLOAK_ADMIN_PASSWORD` из
   `sova-infra/.env.local` (это админ служебного realm `master`, не пользователь
   СОВА).
3. Переключитесь на realm **sova** → Users → Add user.
4. Укажите email и включите **Email verified** — realm требует подтверждённый
   email, а SMTP локально не настроен, поэтому письмо отправить некому.
5. На вкладке Credentials задайте пароль (Temporary = Off).
6. Откройте `http://localhost:3000` и войдите. Django сам выполнит Authorization
   Code flow с PKCE и выдаст HttpOnly session cookie; токены во frontend не
   попадают. После входа имя пользователя видно в правом верхнем углу.

Маршруты авторизации: `GET /api/auth/me/`,
`GET /api/auth/oidc/authenticate/`, `GET /api/auth/oidc/callback/`,
`POST /api/auth/oidc/logout/`.

---

## 5. Остановка и сброс

```bash
cd sova-infra

# остановить, данные сохраняются
docker compose --env-file .env.local -f compose.local.yml down

# полный сброс, включая БД приложения и пользователей Keycloak
docker compose --env-file .env.local -f compose.local.yml down --volumes
```

После сброса с `--volumes` нужно заново прогнать `manage.py migrate` и создать
пользователя в Keycloak.

Логи инфраструктуры:

```bash
docker compose --env-file .env.local -f compose.local.yml logs -f keycloak
```

---

## 6. Проверки перед коммитом

Backend:

```bash
poetry check --lock
poetry run python manage.py check
poetry run python manage.py migrate --noinput
poetry run python manage.py test
```

Frontend:

```bash
pnpm check        # format:check + lint + typecheck + test + build
pnpm test:e2e     # требует: pnpm exec playwright install chromium
```

Перед коммитом Husky форматирует staged-файлы, проверяет типы и гоняет
unit-тесты.

---

## 7. Типичные проблемы

| Симптом | Причина и решение |
| --- | --- |
| `Set POSTGRES_PASSWORD in .env.local` при `up` | Не заполнены обязательные переменные в `sova-infra/.env.local` либо забыт флаг `--env-file .env.local`. |
| Django падает на старте с ошибкой подключения к БД | Контейнеры ещё не `healthy`, либо `POSTGRES_PASSWORD` в `.env.local` и `DATABASE_URL` в `sova-backend/.env` разошлись. |
| `invalid_client` / ошибка на token endpoint Keycloak | `KEYCLOAK_CLIENT_SECRET` различается в `sova-infra/.env.local` и `sova-backend/.env`. После правки секрета realm нужно переимпортировать: `down --volumes` и снова `up -d`. |
| Redirect URI mismatch при входе | Frontend запущен не на 3000. Либо верните порт 3000, либо выставьте `FRONTEND_HOST_PORT` в `.env.local` и пересоздайте Keycloak с `--volumes`. |
| `/api/...` из браузера возвращает 404 | Не запущен Django или `API_PROXY_TARGET` в `sova-frontend/.env.local` указывает не туда. |
| Зацикленные редиректы на `/api/...` | Проверьте, что в `next.config.ts` сохранён `skipTrailingSlashRedirect: true` — Django работает с `APPEND_SLASH`. |
| Telegram-уведомление не приходит | Проверьте, что пользователь отправил боту `/start`, в его профиле указан правильный `Telegram chat ID`, канал Telegram включён, а Django/worker перезапущены после изменения `TELEGRAM_BOT_TOKEN` или `TELEGRAM_PROXY`. Проверьте proxy URL отдельным запросом `curl --proxy "$TELEGRAM_PROXY"`; ошибка Telegram Bot API записывается в лог процесса-отправителя. |
| Порт 5432/6379/8080 занят | Переопределите `*_HOST_PORT` в `.env.local` и синхронно поправьте `sova-backend/.env`. |
