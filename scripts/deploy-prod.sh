#!/usr/bin/env bash
set -Eeuo pipefail

command -v flock >/dev/null || { echo "flock is required." >&2; exit 1; }
exec 9>/tmp/prod-sova-1uup-ru-deploy.lock
flock -n 9 || { echo "Another production deployment is running." >&2; exit 1; }

readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ENV_FILE="${SOVA_PROD_ENV_FILE:-${PROJECT_DIR}/.env.prod}"
readonly RELEASE_FILE="${PROJECT_DIR}/release.prod.env"

[[ -f "${ENV_FILE}" ]] || { echo "Missing ${ENV_FILE}." >&2; exit 1; }
"${PROJECT_DIR}/scripts/validate-release-prod.sh" "${RELEASE_FILE}"
command -v docker >/dev/null
docker compose version >/dev/null

set -a
# Server-owned secret file also uses shell-compatible KEY=VALUE syntax.
# shellcheck disable=SC1090
source "${ENV_FILE}"
# The committed release file is authoritative even if the shell has image tags.
# shellcheck disable=SC1090
source "${RELEASE_FILE}"
set +a

[[ "${ENVIRONMENT:-}" == production ]] || { echo "ENVIRONMENT must be production." >&2; exit 1; }
[[ "${DJANGO_DEBUG:-false}" == false ]] || { echo "DJANGO_DEBUG must be false." >&2; exit 1; }
[[ "${SEED_TEST_ACCOUNTS:-false}" == false ]] || { echo "SEED_TEST_ACCOUNTS must be false." >&2; exit 1; }

required=(DOMAIN AUTH_DOMAIN APP_PUBLIC_URL KEYCLOAK_PUBLIC_URL OIDC_REDIRECT_URI
          DJANGO_ALLOWED_HOSTS CSRF_TRUSTED_ORIGINS POSTGRES_PASSWORD DATABASE_URL
          DJANGO_SECRET_KEY KEYCLOAK_CLIENT_SECRET KEYCLOAK_ADMIN_PASSWORD
          KEYCLOAK_DB_PASSWORD EMAIL_HOST EMAIL_HOST_USER EMAIL_HOST_PASSWORD)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { echo "Set ${name} in ${ENV_FILE}." >&2; exit 1; }
done

COMPOSE_FILES=(-f "${PROJECT_DIR}/compose.yml" -f "${PROJECT_DIR}/compose.prod.yml")
COMPOSE_PROFILES=()
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  COMPOSE_PROFILES=(--profile telegram)
fi
if [[ "${STORAGE_BACKEND:-filesystem}" == s3 ]]; then
  required_s3=(S3_ENDPOINT_URL S3_REGION S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
               S3_MEDIA_BUCKET S3_REPORTS_BUCKET)
  for name in "${required_s3[@]}"; do
    [[ -n "${!name:-}" ]] || { echo "Set ${name} for S3 storage." >&2; exit 1; }
  done
  case "${S3_PROVIDER:-}" in
    garage)
      [[ -n "${GARAGE_RPC_SECRET:-}" && -n "${GARAGE_ADMIN_TOKEN:-}" ]] || {
        echo "Set GARAGE_RPC_SECRET and GARAGE_ADMIN_TOKEN for Garage." >&2
        exit 1
      }
      COMPOSE_FILES+=(-f "${PROJECT_DIR}/compose.s3.yml")
      ;;
    external) ;;
    *) echo "S3_PROVIDER must be garage or external when STORAGE_BACKEND=s3." >&2; exit 1 ;;
  esac
fi

readonly -a COMPOSE=(docker compose --env-file "${ENV_FILE}" --env-file "${RELEASE_FILE}" "${COMPOSE_PROFILES[@]}" "${COMPOSE_FILES[@]}")
"${COMPOSE[@]}" config --quiet

# Existing databases must be backed up before images or schema are changed.
if docker volume inspect prod-sova-1uup-ru_postgres_data >/dev/null 2>&1 ||
   docker volume inspect prod-sova-1uup-ru_keycloak_postgres_data >/dev/null 2>&1; then
  SOVA_PROD_ENV_FILE="${ENV_FILE}" "${PROJECT_DIR}/scripts/backup-prod.sh"
fi

echo "Pulling production images..."
"${COMPOSE[@]}" pull

echo "Starting database, Redis, PDF service and Keycloak..."
"${COMPOSE[@]}" up -d --wait postgres redis gotenberg keycloak-postgres keycloak
"${COMPOSE[@]}" exec -T keycloak /opt/keycloak/configure-keycloak-theme.sh

if [[ "${STORAGE_BACKEND:-filesystem}" == s3 && "${S3_PROVIDER}" == garage ]]; then
  "${COMPOSE[@]}" up -d --wait s3
  "${PROJECT_DIR}/scripts/s3-bootstrap.sh" "${COMPOSE[@]}"
fi

echo "Applying migrations and collecting static files..."
"${COMPOSE[@]}" run --rm backend python manage.py migrate --noinput
"${COMPOSE[@]}" run --rm backend python manage.py check_storage --apply-lifecycle
"${COMPOSE[@]}" run --rm backend python manage.py collectstatic --noinput

"${COMPOSE[@]}" run --rm --no-deps caddy caddy validate \
  --config /etc/caddy/Caddyfile --adapter caddyfile

if ! "${COMPOSE[@]}" up -d --wait --remove-orphans; then
  "${COMPOSE[@]}" ps >&2 || true
  exit 1
fi

# Each release has its own directory, so Caddy must remount the current Caddyfile.
"${COMPOSE[@]}" up -d --force-recreate --wait caddy
healthy=false
for _ in $(seq 1 12); do
  if curl --fail --silent --max-time 10 "https://${DOMAIN}/api/health/" >/dev/null; then
    healthy=true
    break
  fi
  sleep 5
done
if [[ "${healthy}" != true ]]; then
  curl --fail --silent --show-error --max-time 10 "https://${DOMAIN}/api/health/" >/dev/null
  exit 1
fi
"${COMPOSE[@]}" ps
echo "Production release is healthy."
