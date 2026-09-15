#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly ENV_FILE="${PROJECT_DIR}/.env"
readonly -a COMPOSE=(docker compose --env-file "${ENV_FILE}" -f "${PROJECT_DIR}/compose.yml" -f "${PROJECT_DIR}/compose.dev.yml")

usage() {
  echo "Usage: $0 backups/sova_YYYY-MM-DD_HH-MM-SS.sql.gz" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

readonly BACKUP_FILE="$1"

if [[ ! -f "${BACKUP_FILE}" ]]; then
  echo "Backup file does not exist: ${BACKUP_FILE}" >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}." >&2
  exit 1
fi

gzip -t -- "${BACKUP_FILE}"

if ! "${COMPOSE[@]}" ps --status running postgres | grep -q postgres; then
  echo "PostgreSQL is not running." >&2
  exit 1
fi

echo "WARNING: this will replace objects in the SOVA PostgreSQL database."
read -r -p "Type RESTORE to continue: " confirmation
if [[ "${confirmation}" != "RESTORE" ]]; then
  echo "Restore cancelled."
  exit 1
fi

echo "Restoring ${BACKUP_FILE}..."
gzip -dc -- "${BACKUP_FILE}" \
  | "${COMPOSE[@]}" exec -T postgres sh -c \
    'exec psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

echo "Restore completed successfully."
