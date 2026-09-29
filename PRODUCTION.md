Конечно. Сохранил технические названия, пути, переменные и команды без перевода.

# Релизы в production

Production работает на `deploy@77.91.114.59` в `/srv/docker/sova.1uup.ru`.

Домен приложения — `sova.1uup.ru`; Keycloak использует `auth.sova.1uup.ru`.

Compose-проект, сеть и volumes для production отделены от dev-окружения.

Никакие production-секреты или учетные данные GitHub не хранятся в Git.

## Первоначальная настройка

1. Направьте обе DNS A-записи на `77.91.114.59` и откройте TCP-порты 80/443 и UDP-порт 443.

2. На сервере заполните `/srv/docker/sova.1uup.ru/.env.prod` на основе [`.env.prod.example`](*.env.prod.example*) и установите для файла права `600`.

   Укажите все пароли, SMTP-учетные данные и пароль в `DATABASE_URL` в URL-кодированном виде.

   Файл использует совместимый с shell синтаксис `KEY=VALUE`; специальные символы заключайте в кавычки.

   Устанавливайте `TELEGRAM_BOT_TOKEN` только в том случае, если должен запускаться сервис Telegram polling.

3. Если пакеты GHCR приватные, один раз выполните вход от имени пользователя `deploy`, используя токен с правом `read:packages`:

   ```bash
   read -rsp 'GHCR token: ' GHCR_TOKEN && echo
   printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
   unset GHCR_TOKEN
   ```

4. Создайте отдельный SSH-ключ для GitHub Actions workflow репозитория `sova-infra`.

   Добавьте **только его публичный ключ** в `/home/deploy/.ssh/authorized_keys`, а приватный ключ сохраните как секрет `PROD_SSH_KEY` в environment `production` репозитория `sova-infra`.

   Workflow фиксирует ED25519 host key сервера в `.github/known_hosts.prod`.

   Ограничьте права на создание production-тегов и подтверждение environment в соответствии с вашей политикой доступа GitHub.

Production-серверу не требуется доступ через Git к приватному infra-репозиторию.

GitHub Actions передает точное содержимое каждого infra-тега в:

`/srv/docker/sova.1uup.ru/releases/<tag>`

и запускает там `deploy-prod.sh`.

Серверный файл `.env.prod` остается за пределами директорий релизов.

## Релиз

1. Создайте Git-тег формата `vMAJOR.MINOR.PATCH` в `sova-backend` и `sova-frontend`.

   Их отдельные workflow `publish-release.yml` выполняют проверку и публикуют:

   `ghcr.io/abat-voix/sova-backend:<tag>`

   и

   `ghcr.io/abat-voix/sova-frontend:<tag>`

   Дождитесь успешного завершения обоих workflow.

2. Укажите `BACKEND_TAG` и `FRONTEND_TAG` в файле `release.prod.env` репозитория `sova-infra`.

   Версии backend и frontend могут отличаться.

   Закоммитьте файл; секреты должны оставаться только в серверном `.env.prod`.

3. Влейте изменение версий в `sova-infra/develop`, обновите локальную ветку `develop`, а затем одной командой опубликуйте собственный release-тег формата `vMAJOR.MINOR.PATCH`:

   ```bash
   ./scripts/tag-prod-release.sh v1.2.3
   ```

   `deploy-release-prod.yml` загрузит соответствующий snapshot инфраструктуры и выполнит его развертывание.

   Команда откажется выполняться при наличии незакоммиченных изменений или если локальная ветка отличается от удаленной `develop`.

В процессе развертывания выполняются:

- проверка конфигурации и тегов образов;
- резервное копирование существующих баз PostgreSQL;
- загрузка Docker-образов;
- запуск зависимостей;
- применение Django migrations;
- проверка файлового хранилища;
- сбор статических файлов;
- проверка конфигурации Caddy;
- обновление стека;
- проверка `/api/health/`.

При ошибке на любом из этапов workflow останавливается.

Резервные копии находятся в:

`/srv/docker/sova.1uup.ru/backups`

Для них необходимо организовать хранение копий за пределами этого сервера.

Если используется `STORAGE_BACKEND=filesystem`, отдельно создавайте резервную копию volume `django_media`: дампы базы данных не содержат загруженные пользователями файлы.

Если используется S3, создавайте резервную копию соответствующего bucket с помощью механизма резервного копирования вашего storage-провайдера.

Теги являются неизменяемыми идентификаторами релизов.

Чтобы откатить образы приложения, укажите предыдущие теги образов в `release.prod.env`, закоммитьте изменения, влейте их в `develop`, а затем создайте **новый** infra release tag.

При изменениях базы данных может потребоваться восстановление из резервной копии, если миграции не являются обратно совместимыми.

Для ручного повторного запуска существующего релиза на сервере используйте:

```bash
SOVA_PROD_ENV_FILE=/srv/docker/sova.1uup.ru/.env.prod \
  /srv/docker/sova.1uup.ru/releases/v1.2.3/scripts/deploy-prod.sh
```