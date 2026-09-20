# SOVA Infrastructure

СОВА — Система организации взаимодействия с академической средой.

Этот репозиторий хранит инфраструктуру dev-стенда `https://dev.sova.1uup.ru`. Сервер не собирает приложение из исходников: он загружает готовые образы `sova-frontend` и `sova-backend` из GitHub Container Registry (GHCR).

## Architecture

```text
                    Internet
                       |
                       v
                    Caddy
                       |
             +---------+---------+
             |                   |
             v                   v
          Next.js              Django
         frontend              backend
                                  |
                    +-------------+--------+----------+
                    |                      |          |
                    v                      v          v
                PostgreSQL               Redis   Gotenberg

        auth.dev.sova.1uup.ru
                  |
                  v
                Caddy
                  |
                  v
              Keycloak ----> Keycloak PostgreSQL
```

Caddy — единственная публичная точка входа. Он завершает TLS и направляет запросы к сервисам во внутренней Docker-сети:

- `/api/*` и `/admin/*` → `backend:8000`;
- `/static/*` → Django static volume;
- `/media/*` → Django media volume;
- все остальные пути → `frontend:3000`.

PostgreSQL, Redis, Gotenberg, Django и Next.js не публикуют порты на хосте.
Gotenberg доступен только backend во внутренней Docker-сети и преобразует HTML
отчётов в PDF через Chromium. Данные PostgreSQL, Redis, Caddy, static и media
хранятся в named volumes. WebSocket-соединения поддерживаются `reverse_proxy`
Caddy автоматически.

Keycloak доступен только через `https://auth.dev.sova.1uup.ru`; его application
и management-порты наружу не публикуются. Realm `sova` импортируется при первом
старте, а Django использует confidential client `sova-web` и server-side OIDC
flow. Пользовательский браузер хранит только Django session cookie.

## Server requirements

- Linux-сервер с публичными TCP-портами 80 и 443 и UDP-портом 443;
- DNS A/AAAA-запись `dev.sova.1uup.ru`, направленная на сервер;
- DNS A/AAAA-запись `auth.dev.sova.1uup.ru`, направленная на тот же сервер;
- Docker Engine и Docker Compose v2;
- доступ сервера к `ghcr.io`;
- достаточно диска для образов, базы, media и резервных копий.

Установите Docker Engine и Compose plugin по официальной инструкции для дистрибутива. Добавьте операционного пользователя в группу `docker` или запускайте команды с подходящими правами. Убедитесь, что работают:

```bash
docker --version
docker compose version
```

## Initial setup

```bash
git clone https://github.com/abat-voix/sova-infra.git
cd sova-infra
cp .env.example .env
chmod 600 .env
```

Заполните `.env`. Как минимум задайте сильные уникальные значения для
`POSTGRES_PASSWORD`, `DATABASE_URL`, `DJANGO_SECRET_KEY`,
`KEYCLOAK_CLIENT_SECRET`, `KEYCLOAK_ADMIN_PASSWORD` и
`KEYCLOAK_DB_PASSWORD`. Например, `DATABASE_URL` должен ссылаться на
Docker-сервис PostgreSQL:

```dotenv
DATABASE_URL=postgresql://sova:URL_ENCODED_PASSWORD@postgres:5432/sova
```

Если пароль содержит специальные символы, URL-кодируйте их в `DATABASE_URL`. Не коммитьте `.env`: этот файл существует только на сервере.

Для исходящей почты укажите `EMAIL_HOST`, полный адрес созданного ящика в
`EMAIL_HOST_USER` и его отдельный пароль в `EMAIL_HOST_PASSWORD`. Без этих трёх
переменных development-окружение продолжит работать, но письма будут выводиться
в консоль контейнера. SMTP-поля нужно задавать либо все вместе, либо не задавать
вовсе. В production все три переменные обязательны. Конфигурация по умолчанию
использует порт `465` с SSL. Не включайте одновременно
`EMAIL_USE_SSL` и `EMAIL_USE_TLS`.

Эти же SMTP-параметры передаются в realm `sova` для подтверждения email и
восстановления пароля. Если SMTP не настроен в development, первого тестового
пользователя нужно создать в Admin Console с включённым `Email verified`.

Client secret должен совпадать в Django и импортируемом realm; Compose передаёт
одно значение `KEYCLOAK_CLIENT_SECRET` обоим сервисам. Realm import выполняется
только если realm `sova` ещё не существует. Последующее изменение JSON или
секрета в `.env` существующий realm автоматически не обновляет — такие
изменения нужно применить через Keycloak Admin Console либо контролируемый
повторный import.

### Test accounts

Dev deployment может автоматически создать три тестовые учётные записи в
Keycloak: `test-kam`, `test-boss` и `test-admin`. Для этого задайте в серверном
`.env`:

```dotenv
SEED_TEST_ACCOUNTS=true
TEST_KAM_PASSWORD=<UNIQUE_SECRET>
TEST_BOSS_PASSWORD=<UNIQUE_SECRET>
TEST_ADMIN_PASSWORD=<UNIQUE_SECRET>
```

`scripts/deploy.sh` запускает идемпотентный bootstrap после готовности Keycloak.
Отсутствующие пользователи создаются, а существующие включаются и получают имя,
подтверждённый тестовый email и пароль из `.env`. Поэтому ручная смена пароля
тестового аккаунта будет отменена следующим deployment. Bootstrap работает
только при `ENVIRONMENT=development` и не назначает прикладные роли СОВА.

### GHCR authorization

Для публичных образов авторизация не нужна. Для приватных создайте GitHub personal access token с минимальным правом `read:packages` и передайте его только через окружение текущего shell:

```bash
export GHCR_USERNAME=your-github-login
read -rsp 'GHCR token: ' GHCR_TOKEN && export GHCR_TOKEN && echo
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
unset GHCR_TOKEN
```

`scripts/deploy.sh` также выполнит безопасный login через stdin, если одновременно переданы `GHCR_USERNAME` и `GHCR_TOKEN`. Токен не следует сохранять в `.env` или shell history.

## First launch

Проверьте итоговую конфигурацию и запустите deploy:

```bash
docker compose -f compose.yml -f compose.dev.yml config
./scripts/deploy.sh
```

Deploy загружает готовые образы, запускает обе базы PostgreSQL, Redis, Gotenberg
и Keycloak, ожидает их готовности, выполняет Django migrations и `collectstatic`
в одноразовых контейнерах, а затем обновляет весь стек. Persistent volumes
автоматически не удаляются.

Альтернативный ручной запуск без миграций:

```bash
docker compose -f compose.yml -f compose.dev.yml pull
docker compose -f compose.yml -f compose.dev.yml up -d
docker compose -f compose.yml -f compose.dev.yml ps
```

После первого запуска проверьте `https://dev.sova.1uup.ru` и health endpoint `https://dev.sova.1uup.ru/api/health/`.

Затем откройте `https://auth.dev.sova.1uup.ru/admin/`, войдите bootstrap-admin
учётной записью, переключитесь в realm `sova` и создайте первого пользователя.
Для пользователя укажите email; realm требует подтверждение email. Bootstrap
admin относится к служебному realm `master` и не является пользователем СОВА.

## Local development

Локально frontend и backend запускаются обычными командами из их репозиториев,
а вся инфраструктура — PostgreSQL приложения, Redis, Gotenberg, Keycloak и
PostgreSQL Keycloak — поднимается из `compose.local.yml`. Этот файл использует собственный
env-файл `.env.local`; не путайте его с `.env`, который описывает dev-стенд и
существует только на сервере.

```bash
cp .env.local.example .env.local
chmod 600 .env.local
# заполните POSTGRES_PASSWORD, KEYCLOAK_CLIENT_SECRET,
# KEYCLOAK_ADMIN_PASSWORD и KEYCLOAK_DB_PASSWORD
docker compose --env-file .env.local -f compose.local.yml up -d
docker compose --env-file .env.local -f compose.local.yml ps
```

Все порты публикуются только на `127.0.0.1`:

| Сервис | Адрес | Переменная порта |
| --- | --- | --- |
| PostgreSQL приложения | `localhost:5432`, база `sova` | `POSTGRES_HOST_PORT` |
| Redis | `localhost:6379` | `REDIS_HOST_PORT` |
| Gotenberg | `http://localhost:3001` | `GOTENBERG_HOST_PORT` |
| Keycloak | `http://localhost:8080` | `KEYCLOAK_HOST_PORT` |
| PostgreSQL Keycloak | не публикуется | — |

Если порт занят другим проектом, переопределите соответствующую `*_HOST_PORT` в
`.env.local` и синхронно поправьте `DATABASE_URL`/`REDIS_URL` в
`sova-backend/.env`. Изменение `KEYCLOAK_HOST_PORT` автоматически меняет
`KC_HOSTNAME`, а `FRONTEND_HOST_PORT` — `rootUrl` и redirect URI клиента
`sova-web` в импортируемом realm.

Затем в `sova-backend/.env` укажите:

```dotenv
DATABASE_URL=postgresql://sova:<POSTGRES_PASSWORD>@localhost:5432/sova
REDIS_URL=redis://localhost:6379/0
GOTENBERG_URL=http://localhost:3001
KEYCLOAK_CLIENT_SECRET=<то же значение, что в .env.local>
```

Client secret должен совпадать в обоих файлах: realm импортирует именно то
значение, которое Django затем предъявляет на token endpoint.

Realm разрешает callback через локальный Next.js proxy:
`http://localhost:3000/api/auth/oidc/callback/`.

Остановка без удаления данных:

```bash
docker compose --env-file .env.local -f compose.local.yml down
```

Полный сброс локальных баз, включая пользователей Keycloak:

```bash
docker compose --env-file .env.local -f compose.local.yml down --volumes
```

## Routine operations

Обычное обновление приложения после публикации новых образов:

```bash
./scripts/deploy.sh
```

Для воспроизводимого обновления предпочтительно указать в `.env` неизменяемые теги образов (например, git SHA), а не перемещаемый тег `dev`.

Состояние и логи:

```bash
docker compose -f compose.yml -f compose.dev.yml ps
docker compose -f compose.yml -f compose.dev.yml logs -f
docker compose -f compose.yml -f compose.dev.yml logs -f backend
```

Остановка контейнеров без удаления данных:

```bash
docker compose -f compose.yml -f compose.dev.yml down
```

Не добавляйте `--volumes`, если удаление persistent data не является осознанным действием.

## Backup

Создать сжатый SQL backup PostgreSQL:

```bash
./scripts/backup.sh
```

Будут созданы два файла:

- `backups/sova_YYYY-MM-DD_HH-MM-SS.sql.gz`;
- `backups/keycloak_YYYY-MM-DD_HH-MM-SS.sql.gz`.

Оба файла создаются с правами только для текущего пользователя. Каталог
`backups/` исключён из Git. Храните обе базы согласованно: Keycloak содержит
пользователей и credentials, а SOVA — ссылки на Keycloak `sub`.

## Restore

Восстановление — явная ручная операция:

```bash
./scripts/restore.sh backups/sova_YYYY-MM-DD_HH-MM-SS.sql.gz
./scripts/restore.sh backups/keycloak_YYYY-MM-DD_HH-MM-SS.sql.gz
```

Скрипт выбирает базу по имени файла, проверяет gzip, требует ввести `RESTORE` и
запускает `psql` с остановкой при первой SQL-ошибке. Перед восстановлением
сделайте актуальный backup и остановите запись приложения в обе базы (включая
`backend`, `frontend` и `keycloak`). Restore никогда не запускается из deploy.

## Requirements for application repositories

### `sova-frontend`

- Текущий Dockerfile уже создаёт standalone production image, слушает `0.0.0.0:3000` и запускается от пользователя `nextjs`; эти свойства нужно сохранить.
- Dockerfile должен собирать production image, опубликованный как `ghcr.io/abat-voix/sova-frontend:<tag>`.
- Контейнер должен слушать `0.0.0.0:3000` и запускать production Next.js server, а не dev server.
- Image должен содержать Node.js с поддержкой `fetch`, используемого healthcheck.
- Приложение должно корректно работать за reverse proxy и использовать относительный `/api` либо публичный origin `https://dev.sova.1uup.ru`.
- Контейнер следует запускать от непривилегированного пользователя, определённого в Dockerfile.
- GitHub Actions frontend-репозитория должен собирать, проверять и публиковать образ в GHCR; сервер не должен собирать frontend. Workflow публикации создаёт теги `dev` и `sha-<commit>`.

### `sova-backend`

- Dockerfile должен собирать production image, опубликованный как `ghcr.io/abat-voix/sova-backend:<tag>`.
- Контейнер должен слушать `0.0.0.0:8000` через production WSGI/ASGI server (например, Gunicorn/Uvicorn), а не `runserver`.
- Настройки должны читать `DATABASE_URL`, `REDIS_URL`, `DJANGO_SECRET_KEY`, `DJANGO_ALLOWED_HOSTS`, `CSRF_TRUSTED_ORIGINS`, `DJANGO_DEBUG`, `STATIC_ROOT` и `MEDIA_ROOT`.
- Для генерации PDF backend должен читать `GOTENBERG_URL` и обращаться к Gotenberg только через внутреннюю Docker-сеть.
- OIDC-настройки должны читать `APP_PUBLIC_URL`, `KEYCLOAK_PUBLIC_URL`, `KEYCLOAK_INTERNAL_URL`, `KEYCLOAK_REALM`, `KEYCLOAK_CLIENT_ID` и `KEYCLOAK_CLIENT_SECRET`.
- Должен существовать неаутентифицированный лёгкий endpoint `GET /api/health/`, возвращающий успешный HTTP-код после готовности процесса.
- `collectstatic` должен складывать файлы в `/app/staticfiles`; загружаемые media — в `/app/media`. Оба пути являются persistent volumes и доступны Caddy только для чтения.
- При работе за proxy Django должен доверять `X-Forwarded-Proto` от Caddy (обычно `SECURE_PROXY_SSL_HEADER`) и корректно определять HTTPS.
- Миграции должны поддерживать `python manage.py migrate --noinput` и быть обратно совместимыми при rolling-style обновлении.
- Контейнер следует запускать от непривилегированного пользователя, определённого в Dockerfile, с правами записи в static/media volumes.
- GitHub Actions backend-репозитория должен собирать, проверять и публиковать образ в GHCR; сервер не должен собирать backend. Workflow публикации создаёт теги `dev` и `sha-<commit>`.

## Troubleshooting

Показать раскрытую Compose-конфигурацию:

```bash
docker compose -f compose.yml -f compose.dev.yml config
```

Если сервис unhealthy, проверьте его healthcheck и логи:

```bash
docker compose -f compose.yml -f compose.dev.yml ps
docker inspect --format '{{json .State.Health}}' sova-backend-1
docker compose -f compose.yml -f compose.dev.yml logs --tail=200 backend
docker compose -f compose.yml -f compose.dev.yml logs --tail=200 keycloak
```

Если Caddy не получает сертификат, проверьте DNS, доступность портов 80/443, firewall и логи `caddy`. Если образы не загружаются, проверьте точность тегов и `docker login ghcr.io`. Если миграции падают, контейнеры приложения не обновляются, а ошибка возвращается вызывающему shell.

Для повторного сбора static после обновления backend (если image не выполняет это на старте):

```bash
docker compose -f compose.yml -f compose.dev.yml run --rm backend python manage.py collectstatic --noinput
```

## Security notes

- Секреты находятся только в серверном `.env`; сертификаты Caddy — в named volume.
- PostgreSQL и Redis закреплены на major version, Caddy — на major, а Gotenberg
  и Keycloak — на точных security-patch версиях. Перед обновлением Keycloak
  нужно проверить его migration guide и сделать backup обеих баз.
- `no-new-privileges` включён для всех сервисов; приложение должно задавать непривилегированного пользователя внутри собственных Dockerfile.
- Не публикуйте PostgreSQL, Redis, Gotenberg или application ports и не добавляйте секреты в Compose-файлы.
- Эта конфигурация сама по себе не обеспечивает соответствие 152-ФЗ, требованиям ФСТЭК или другим режимам регулирования. Такое соответствие требует отдельного комплекса организационных и технических мер.

## Production extension

Для production добавьте отдельный `compose.prod.yml`, production domain и отдельный `.env`, не меняя базовый `compose.yml`. Не используйте dev и production с одним Compose project name или общими volumes на одном хосте.
