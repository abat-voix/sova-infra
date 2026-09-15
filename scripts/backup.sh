#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly ENV_FILE="${PROJECT_DIR}/.env"
readonly BACKUP_DIR="${PROJECT_DIR}/backups"
readonly TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
readonly BACKUP_FILE="${BACKUP_DIR}/sova_${TIMESTAMP}.sql.gz"
readonly TEMP_FILE="${BACKUP_FILE}.tmp"
readonly -a COMPOSE=(docker compose --env-file "${ENV_FILE}" -f "${PROJECT_DIR}/compose.yml" -f "${PROJECT_DIR}/compose.dev.yml")

cleanup() {
  local exit_code=$?
  if [[ ${exit_code} -ne 0 ]]; then
    rm -f -- "${TEMP_FILE}"
    echo "Backup failed (exit code ${exit_code})." >&2
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}." >&2
  exit 1
fi

mkdir -p -- "${BACKUP_DIR}"
umask 077

if ! "${COMPOSE[@]}" ps --status running postgres | grep -q postgres; then
  echo "PostgreSQL is not running." >&2
  exit 1
fi

echo "Creating ${BACKUP_FILE}..."
"${COMPOSE[@]}" exec -T postgres sh -c \
  'exec pg_dump --clean --if-exists --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  | gzip -9 >"${TEMP_FILE}"

mv -- "${TEMP_FILE}" "${BACKUP_FILE}"
echo "Backup created: ${BACKUP_FILE}"
