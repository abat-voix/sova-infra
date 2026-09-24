#!/usr/bin/env bash

set -Eeuo pipefail

exec 9>/tmp/dev-sova-1uup-ru-deploy.lock

if ! flock -n 9; then
  echo "Another SOVA deployment is already running." >&2
  exit 1
fi

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly ENV_FILE="${PROJECT_DIR}/.env"

on_error() {
  local exit_code=$?
  echo "Deploy failed (exit code ${exit_code}) at line ${BASH_LINENO[0]}." >&2
  exit "${exit_code}"
}
trap on_error ERR

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env and fill in all secrets." >&2
  exit 1
fi

command -v docker >/dev/null 2>&1 || {
  echo "Docker is not installed or is not available in PATH." >&2
  exit 1
}
docker compose version >/dev/null

# S3_PROVIDER decides whether the project's own Garage service is part of this deploy at all
# (compose.s3.yml); with an external S3 provider the S3_* variables already point elsewhere.
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

COMPOSE_FILES=(-f "${PROJECT_DIR}/compose.yml" -f "${PROJECT_DIR}/compose.dev.yml")
if [[ "${S3_PROVIDER:-garage}" == "garage" ]]; then
  COMPOSE_FILES+=(-f "${PROJECT_DIR}/compose.s3.yml")
fi
readonly -a COMPOSE=(docker compose --env-file "${ENV_FILE}" "${COMPOSE_FILES[@]}")

if [[ -n "${GHCR_USERNAME:-}" || -n "${GHCR_TOKEN:-}" ]]; then
  if [[ -z "${GHCR_USERNAME:-}" || -z "${GHCR_TOKEN:-}" ]]; then
    echo "Set both GHCR_USERNAME and GHCR_TOKEN, or neither." >&2
    exit 1
  fi

  printf '%s' "${GHCR_TOKEN}" | docker login ghcr.io --username "${GHCR_USERNAME}" --password-stdin
fi

echo "Pulling application and infrastructure images..."
"${COMPOSE[@]}" pull

echo "Starting PostgreSQL, Redis, Gotenberg, and Keycloak..."
"${COMPOSE[@]}" up -d --wait postgres redis gotenberg keycloak-postgres keycloak

if [[ "${S3_PROVIDER:-garage}" == "garage" ]]; then
  echo "Starting Garage..."
  "${COMPOSE[@]}" up -d --wait s3

  echo "Bootstrapping Garage (layout, buckets, application key)..."
  "${SCRIPT_DIR}/s3-bootstrap.sh" "${COMPOSE[@]}"
fi

echo "Reconciling optional Keycloak test accounts..."
"${COMPOSE[@]}" --profile test-data run --rm keycloak-test-user-bootstrap

echo "Applying Django migrations..."
"${COMPOSE[@]}" run --rm backend python manage.py migrate --noinput

echo "Checking file storage..."
"${COMPOSE[@]}" run --rm backend python manage.py check_storage --apply-lifecycle

echo "Collecting Django static files..."
"${COMPOSE[@]}" run --rm backend python manage.py collectstatic --noinput

echo "Validating Caddy configuration before applying the new routing..."
"${COMPOSE[@]}" run --rm --no-deps caddy caddy validate \
  --config /etc/caddy/Caddyfile \
  --adapter caddyfile

echo "Starting or updating the application and report jobs..."
if ! "${COMPOSE[@]}" up -d --wait --remove-orphans; then
  echo "Compose failed while waiting for services. Current service state:" >&2
  "${COMPOSE[@]}" ps >&2 || true
  exit 1
fi

# Git updates tracked files by replacing their inode. A running container can
# therefore keep the previous bind-mounted Caddyfile even after `git pull`.
# Recreate Caddy so the mount always points at the current file before serving.
echo "Recreating Caddy with the current mounted configuration..."
"${COMPOSE[@]}" up -d --force-recreate --wait caddy

if [[ -n "${REALTIME_SMOKE_URL:-}" || -n "${REALTIME_SMOKE_SESSION_COOKIE:-}" ]]; then
  if [[ -z "${REALTIME_SMOKE_URL:-}" || -z "${REALTIME_SMOKE_SESSION_COOKIE:-}" ]]; then
    echo "Set both REALTIME_SMOKE_URL and REALTIME_SMOKE_SESSION_COOKIE to run the WebSocket smoke check." >&2
    exit 1
  fi
  echo "Checking WebSocket handshake and heartbeat with the supplied session..."
  python3 "${PROJECT_DIR}/scripts/websocket-smoke.py"
else
  echo "WebSocket smoke check skipped; supply a dev test session via REALTIME_SMOKE_URL and REALTIME_SMOKE_SESSION_COOKIE."
fi

echo "Current service state:"
"${COMPOSE[@]}" ps
