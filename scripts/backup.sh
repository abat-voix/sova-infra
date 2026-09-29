#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly ENV_FILE="${PROJECT_DIR}/.env"
readonly BACKUP_DIR="${PROJECT_DIR}/backups"
readonly TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
readonly SOVA_BACKUP_FILE="${BACKUP_DIR}/sova_${TIMESTAMP}.sql.gz"
readonly KEYCLOAK_BACKUP_FILE="${BACKUP_DIR}/keycloak_${TIMESTAMP}.sql.gz"
readonly SOVA_TEMP_FILE="${SOVA_BACKUP_FILE}.tmp"
readonly KEYCLOAK_TEMP_FILE="${KEYCLOAK_BACKUP_FILE}.tmp"
readonly S3_BACKUP_DIR="${BACKUP_DIR}/s3"
readonly RCLONE_IMAGE="rclone/rclone:1.75.0"
readonly -a COMPOSE=(docker compose --env-file "${ENV_FILE}" -f "${PROJECT_DIR}/compose.yml" -f "${PROJECT_DIR}/compose.dev.yml")

cleanup() {
  local exit_code=$?
  if [[ ${exit_code} -ne 0 ]]; then
    rm -f -- "${SOVA_TEMP_FILE}" "${KEYCLOAK_TEMP_FILE}"
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

for service in postgres keycloak-postgres; do
  if ! "${COMPOSE[@]}" ps --status running "${service}" | grep -q "${service}"; then
    echo "${service} is not running." >&2
    exit 1
  fi
done

echo "Creating ${SOVA_BACKUP_FILE}..."
"${COMPOSE[@]}" exec -T postgres sh -c \
  'exec pg_dump --clean --if-exists --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  | gzip -9 >"${SOVA_TEMP_FILE}"

echo "Creating ${KEYCLOAK_BACKUP_FILE}..."
"${COMPOSE[@]}" exec -T keycloak-postgres sh -c \
  'exec pg_dump --clean --if-exists --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  | gzip -9 >"${KEYCLOAK_TEMP_FILE}"

mv -- "${SOVA_TEMP_FILE}" "${SOVA_BACKUP_FILE}"
mv -- "${KEYCLOAK_TEMP_FILE}" "${KEYCLOAK_BACKUP_FILE}"
echo "Backups created:"
echo "  ${SOVA_BACKUP_FILE}"
echo "  ${KEYCLOAK_BACKUP_FILE}"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

if [[ -n "${S3_ACCESS_KEY_ID:-}" && "${STORAGE_BACKEND:-filesystem}" == "s3" ]]; then
  # Garage/S3 has no versioning: --backup-dir keeps whatever a sync would otherwise delete or
  # overwrite, so a deleted or replaced object is not gone from the backup either. Only the
  # media bucket (attachments, contracts) is mirrored — the reports bucket holds throwaway files.
  : "${S3_MEDIA_BUCKET:?Set S3_MEDIA_BUCKET in .env}"
  : "${S3_BACKUP_DELETED_RETENTION_DAYS:=90}"
  mkdir -p -- "${S3_BACKUP_DIR}/current"

  RCLONE_NETWORK_ARGS=()
  if [[ "${S3_PROVIDER:-garage}" == "garage" ]]; then
    RCLONE_NETWORK_ARGS=(--network dev-sova-1uup-ru)
  fi

  echo "Mirroring S3 bucket ${S3_MEDIA_BUCKET} to ${S3_BACKUP_DIR}..."
  docker run --rm "${RCLONE_NETWORK_ARGS[@]}" \
    -e RCLONE_CONFIG_SOVA_TYPE=s3 \
    -e RCLONE_CONFIG_SOVA_PROVIDER=Other \
    -e RCLONE_CONFIG_SOVA_ENDPOINT="${S3_ENDPOINT_URL}" \
    -e RCLONE_CONFIG_SOVA_REGION="${S3_REGION}" \
    -e RCLONE_CONFIG_SOVA_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}" \
    -e RCLONE_CONFIG_SOVA_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}" \
    -e RCLONE_CONFIG_SOVA_FORCE_PATH_STYLE=true \
    -v "${S3_BACKUP_DIR}:/backup" \
    "${RCLONE_IMAGE}" \
    sync "sova:${S3_MEDIA_BUCKET}" /backup/current \
    --backup-dir "/backup/deleted/${TIMESTAMP}"

  if [[ -d "${S3_BACKUP_DIR}/deleted/${TIMESTAMP}" ]]; then
    echo "Objects removed or replaced since the last backup were kept under" \
      "${S3_BACKUP_DIR}/deleted/${TIMESTAMP}/"
  fi

  echo "Pruning ${S3_BACKUP_DIR}/deleted/ entries older than ${S3_BACKUP_DELETED_RETENTION_DAYS} days..."
  find "${S3_BACKUP_DIR}/deleted" -mindepth 1 -maxdepth 1 -type d \
    -mtime "+${S3_BACKUP_DELETED_RETENTION_DAYS}" -exec rm -rf -- {} + 2>/dev/null || true
else
  echo "STORAGE_BACKEND is not s3 (or S3_ACCESS_KEY_ID is unset) — skipping S3 bucket backup."
fi
