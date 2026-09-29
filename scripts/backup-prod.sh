#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ENV_FILE="${SOVA_PROD_ENV_FILE:-${PROJECT_DIR}/.env.prod}"
readonly RELEASE_FILE="${PROJECT_DIR}/release.prod.env"
readonly BACKUP_DIR="$(dirname -- "${ENV_FILE}")/backups"
readonly TIMESTAMP="$(date -u '+%Y-%m-%d_%H-%M-%S')"
readonly -a COMPOSE=(docker compose --env-file "${ENV_FILE}" --env-file "${RELEASE_FILE}" -f "${PROJECT_DIR}/compose.yml" -f "${PROJECT_DIR}/compose.prod.yml")

[[ -f "${ENV_FILE}" ]] || { echo "Missing ${ENV_FILE}." >&2; exit 1; }
"${PROJECT_DIR}/scripts/validate-release-prod.sh" "${RELEASE_FILE}" >/dev/null
set -a
# shellcheck disable=SC1090
source "${RELEASE_FILE}"
set +a
mkdir -p -- "${BACKUP_DIR}"
umask 077

for service in postgres keycloak-postgres; do
  file="${BACKUP_DIR}/${service}_${TIMESTAMP}.sql.gz"
  echo "Backing up ${service} to ${file}..."
  if ! "${COMPOSE[@]}" exec -T "${service}" sh -c \
    'exec pg_dump --clean --if-exists --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
    | gzip -9 >"${file}.tmp"; then
    rm -f -- "${file}.tmp"
    echo "Backup failed for ${service}; deployment stopped." >&2
    exit 1
  fi
  mv -- "${file}.tmp" "${file}"
done
