# Production releases

Production runs on `deploy@77.91.114.59` in `/srv/docker/sova.1uup.ru`.
The application domain is `sova.1uup.ru`; Keycloak uses `auth.sova.1uup.ru`.
The production Compose project, network and volumes are separate from dev.
No production secrets or GitHub credentials are committed to Git.

## One-time setup

1. Point both DNS A records to `77.91.114.59` and open TCP 80/443 and UDP 443.
2. On the server, fill `/srv/docker/sova.1uup.ru/.env.prod` from
   [`.env.prod.example`](.env.prod.example) and keep it mode `600`. Set all
   passwords, SMTP credentials and a URL-encoded `DATABASE_URL` password.
   The file is shell-compatible `KEY=VALUE` syntax; quote special characters.
   Set `TELEGRAM_BOT_TOKEN` only if the Telegram polling service should run.
3. If GHCR packages are private, log in once as `deploy` with a token carrying
   `read:packages`:

   ```bash
   read -rsp 'GHCR token: ' GHCR_TOKEN && echo
   printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
   unset GHCR_TOKEN
   ```

4. Create a dedicated SSH key for the `sova-infra` GitHub Actions workflow.
   Add only its public key to `/home/deploy/.ssh/authorized_keys`; store its
   private key as the `PROD_SSH_KEY` secret in the `production` environment of
   the `sova-infra` repository. The workflow pins the server's ED25519 host key
   in `.github/known_hosts.prod`. Restrict who may create production tags or
   approve that environment according to your GitHub access policy.

The production server does not need Git access to the private infra repository.
GitHub Actions transfers the exact contents of each infra tag into
`/srv/docker/sova.1uup.ru/releases/<tag>` and runs `deploy-prod.sh` there.
The server-only `.env.prod` stays outside release directories.

## Release

1. Create a `vMAJOR.MINOR.PATCH` Git tag in `sova-backend` and `sova-frontend`.
   Their separate `publish-release.yml` workflows verify and publish
   `ghcr.io/abat-voix/sova-backend:<tag>` and
   `ghcr.io/abat-voix/sova-frontend:<tag>`. Wait for both workflows to succeed.
2. Set `BACKEND_TAG` and `FRONTEND_TAG` in `release.prod.env` in `sova-infra`.
   They may be different versions. Commit the file; keep secrets in the
   server-only `.env.prod`.
3. Merge the version change into `sova-infra/develop`, update your local
   `develop`, then publish its own `vMAJOR.MINOR.PATCH` release tag with one
   command:

   ```bash
   ./scripts/tag-prod-release.sh v1.2.3
   ```

   `deploy-release-prod.yml` uploads that infra snapshot and deploys it. The
   command refuses uncommitted changes or a branch that differs from remote
   `develop`.

The deployment validates configuration and image tags, backs up existing
PostgreSQL databases, pulls images, starts dependencies, applies Django
migrations, checks file storage, collects static files, validates Caddy,
updates the stack and checks `/api/health/`. A failed step stops the workflow.
Backups are in `/srv/docker/sova.1uup.ru/backups` and need off-server retention.
If `STORAGE_BACKEND=filesystem`, back up the `django_media` volume separately;
database dumps do not contain uploaded files. If S3 is used, back up that
bucket through the storage provider's backup mechanism.

Tags are immutable release identifiers. To roll back application images,
commit previous image tags to `release.prod.env`, merge them into `develop`,
and create a **new** infra release tag. Database changes may need a restore
from backup if migrations are not backward compatible.

For a manual retry of an existing release on the server:

```bash
SOVA_PROD_ENV_FILE=/srv/docker/sova.1uup.ru/.env.prod \
  /srv/docker/sova.1uup.ru/releases/v1.2.3/scripts/deploy-prod.sh
```
