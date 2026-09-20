#!/usr/bin/env bash

set -Eeuo pipefail

exec 9>/tmp/sova-deploy.lock

if ! flock -n 9; then
  echo "Another SOVA deployment is already running." >&2
  exit 1
fi

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly ENV_FILE="${PROJECT_DIR}/.env"
readonly -a COMPOSE=(docker compose --env-file "${ENV_FILE}" -f "${PROJECT_DIR}/compose.yml" -f "${PROJECT_DIR}/compose.dev.yml")

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

echo "Applying Django migrations..."
"${COMPOSE[@]}" run --rm backend python manage.py migrate --noinput

echo "Collecting Django static files..."
"${COMPOSE[@]}" run --rm backend python manage.py collectstatic --noinput

echo "Starting or updating the application..."
"${COMPOSE[@]}" up -d --remove-orphans

echo "Current service state:"
"${COMPOSE[@]}" ps
