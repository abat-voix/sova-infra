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
                         +--------+--------+
                         |                 |
                         v                 v
                     PostgreSQL          Redis
```

Caddy — единственная публичная точка входа. Он завершает TLS и направляет запросы к сервисам во внутренней Docker-сети:

- `/api/*` и `/admin/*` → `backend:8000`;
- `/static/*` → Django static volume;
- `/media/*` → Django media volume;
- все остальные пути → `frontend:3000`.

PostgreSQL, Redis, Django и Next.js не публикуют порты на хосте. Данные PostgreSQL, Redis, Caddy, static и media хранятся в named volumes. WebSocket-соединения поддерживаются `reverse_proxy` Caddy автоматически.

## Server requirements

- Linux-сервер с публичными TCP-портами 80 и 443 и UDP-портом 443;
- DNS A/AAAA-запись `dev.sova.1uup.ru`, направленная на сервер;
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

Заполните `.env`. Как минимум задайте сильные уникальные значения для `POSTGRES_PASSWORD`, `DATABASE_URL` и `DJANGO_SECRET_KEY`. Например, `DATABASE_URL` должен ссылаться на Docker-сервис PostgreSQL:

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

Deploy загружает готовые образы, запускает PostgreSQL и Redis, ожидает их готовности, выполняет Django migrations и `collectstatic` в одноразовых контейнерах, а затем обновляет весь стек. Persistent volumes автоматически не удаляются.

Альтернативный ручной запуск без миграций:

```bash
docker compose -f compose.yml -f compose.dev.yml pull
docker compose -f compose.yml -f compose.dev.yml up -d
docker compose -f compose.yml -f compose.dev.yml ps
```

После первого запуска проверьте `https://dev.sova.1uup.ru` и health endpoint `https://dev.sova.1uup.ru/api/health/`.

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

Файл будет создан как `backups/sova_YYYY-MM-DD_HH-MM-SS.sql.gz` с правами только для текущего пользователя. Каталог `backups/` исключён из Git. Скопируйте backup в защищённое внешнее хранилище и настройте отдельную политику хранения и проверки восстановления.

## Restore

Восстановление — явная ручная операция:

```bash
./scripts/restore.sh backups/sova_YYYY-MM-DD_HH-MM-SS.sql.gz
```

Скрипт проверяет gzip-файл, требует ввести `RESTORE` и запускает `psql` с остановкой при первой SQL-ошибке. Перед восстановлением сделайте актуальный backup и остановите запись приложения в базу (например, временно остановите `backend` и `frontend`). Restore никогда не запускается из deploy.

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
```

Если Caddy не получает сертификат, проверьте DNS, доступность портов 80/443, firewall и логи `caddy`. Если образы не загружаются, проверьте точность тегов и `docker login ghcr.io`. Если миграции падают, контейнеры приложения не обновляются, а ошибка возвращается вызывающему shell.

Для повторного сбора static после обновления backend (если image не выполняет это на старте):

```bash
docker compose -f compose.yml -f compose.dev.yml run --rm backend python manage.py collectstatic --noinput
```

## Security notes

- Секреты находятся только в серверном `.env`; сертификаты Caddy — в named volume.
- Stateful images закреплены на major version (`postgres:17-alpine`, `redis:7-alpine`), а Caddy — на `caddy:2-alpine`. Перед major upgrade нужен отдельный план миграции.
- `no-new-privileges` включён для всех сервисов; приложение должно задавать непривилегированного пользователя внутри собственных Dockerfile.
- Не публикуйте PostgreSQL, Redis или application ports и не добавляйте секреты в Compose-файлы.
- Эта конфигурация сама по себе не обеспечивает соответствие 152-ФЗ, требованиям ФСТЭК или другим режимам регулирования. Такое соответствие требует отдельного комплекса организационных и технических мер.

## Production extension

Для production добавьте отдельный `compose.prod.yml`, production domain и отдельный `.env`, не меняя базовый `compose.yml`. Не используйте dev и production с одним Compose project name или общими volumes на одном хосте.
