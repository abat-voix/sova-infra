#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly ENV_FILE="${PROJECT_DIR}/.env"
readonly BACKUP_DIR="${PROJECT_DIR}/backups"
readonly RCLONE_IMAGE="rclone/rclone:1.75.0"
readonly -a COMPOSE=(docker compose --env-file "${ENV_FILE}" -f "${PROJECT_DIR}/compose.yml" -f "${PROJECT_DIR}/compose.dev.yml")

usage() {
  echo "Usage: $0 backups/{sova|keycloak}_YYYY-MM-DD_HH-MM-SS.sql.gz" >&2
  echo "       $0 s3                                    # restore the S3 media bucket from backups/s3/current" >&2
  echo "       $0 s3 backups/s3/deleted/YYYY-MM-DD_HH-MM-SS  # restore one deleted/replaced snapshot on top" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

if [[ "$1" == "s3" ]]; then
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Missing ${ENV_FILE}." >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
  : "${S3_ACCESS_KEY_ID:?Set S3_ACCESS_KEY_ID in .env}"
  : "${S3_MEDIA_BUCKET:?Set S3_MEDIA_BUCKET in .env}"

  readonly SOURCE_DIR="${2:-${BACKUP_DIR}/s3/current}"
  if [[ ! -d "${SOURCE_DIR}" ]]; then
    echo "No such backup directory: ${SOURCE_DIR}" >&2
    exit 1
  fi

  echo "WARNING: this copies ${SOURCE_DIR} into bucket ${S3_MEDIA_BUCKET}, overwriting objects"
  echo "with the same key. Existing objects not present in ${SOURCE_DIR} are left untouched."
  read -r -p "Type RESTORE to continue: " confirmation
  if [[ "${confirmation}" != "RESTORE" ]]; then
    echo "Restore cancelled."
    exit 1
  fi

  RCLONE_NETWORK_ARGS=()
  if [[ "${S3_PROVIDER:-garage}" == "garage" ]]; then
    RCLONE_NETWORK_ARGS=(--network dev-sova-1uup-ru)
  fi

  docker run --rm "${RCLONE_NETWORK_ARGS[@]}" \
    -e RCLONE_CONFIG_SOVA_TYPE=s3 \
    -e RCLONE_CONFIG_SOVA_PROVIDER=Other \
    -e RCLONE_CONFIG_SOVA_ENDPOINT="${S3_ENDPOINT_URL}" \
    -e RCLONE_CONFIG_SOVA_REGION="${S3_REGION}" \
    -e RCLONE_CONFIG_SOVA_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}" \
    -e RCLONE_CONFIG_SOVA_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}" \
    -e RCLONE_CONFIG_SOVA_FORCE_PATH_STYLE=true \
    -v "${SOURCE_DIR}:/backup:ro" \
    "${RCLONE_IMAGE}" \
    copy /backup "sova:${S3_MEDIA_BUCKET}"

  echo "Restore completed successfully."
  exit 0
fi

readonly BACKUP_FILE="$1"

case "$(basename -- "${BACKUP_FILE}")" in
  sova_*.sql.gz)
    readonly DATABASE_SERVICE="postgres"
    readonly DATABASE_LABEL="SOVA"
    ;;
  keycloak_*.sql.gz)
    readonly DATABASE_SERVICE="keycloak-postgres"
    readonly DATABASE_LABEL="Keycloak"
    ;;
  *)
    echo "Backup filename must start with sova_ or keycloak_." >&2
    exit 1
    ;;
esac

if [[ ! -f "${BACKUP_FILE}" ]]; then
  echo "Backup file does not exist: ${BACKUP_FILE}" >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}." >&2
  exit 1
fi

gzip -t -- "${BACKUP_FILE}"

if ! "${COMPOSE[@]}" ps --status running "${DATABASE_SERVICE}" | grep -q "${DATABASE_SERVICE}"; then
  echo "${DATABASE_SERVICE} is not running." >&2
  exit 1
fi

echo "WARNING: this will replace objects in the ${DATABASE_LABEL} PostgreSQL database."
read -r -p "Type RESTORE to continue: " confirmation
if [[ "${confirmation}" != "RESTORE" ]]; then
  echo "Restore cancelled."
  exit 1
fi

echo "Restoring ${BACKUP_FILE}..."
gzip -dc -- "${BACKUP_FILE}" \
  | "${COMPOSE[@]}" exec -T "${DATABASE_SERVICE}" sh -c \
    'exec psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

echo "Restore completed successfully."
