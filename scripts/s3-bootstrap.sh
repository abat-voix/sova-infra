#!/usr/bin/env bash
#
# Bootstraps the Garage cluster used as the project's own S3-compatible storage:
# single-node layout, the two application buckets, and an access key scoped to them.
# Idempotent — safe to run on every deploy; each step is skipped if already done.
#
# Not used for an external S3 provider (S3_PROVIDER=external): there the buckets and the
# access key already exist outside this project.
#
# Usage: s3-bootstrap.sh <docker compose invocation...>
# Example: scripts/s3-bootstrap.sh docker compose --env-file .env -f compose.yml -f compose.s3.yml
#
# NOTE: written from the Garage v2.3.0 CLI reference without a live cluster to verify
# against. Re-check the exact flags with `garage --help` / `garage <subcommand> --help`
# inside the running container the first time this deploys, and fix this script if the
# output differs.

set -Eeuo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <docker compose ...>" >&2
  exit 1
fi
readonly -a COMPOSE=("$@")

: "${S3_ACCESS_KEY_ID:?Set S3_ACCESS_KEY_ID in .env}"
: "${S3_SECRET_ACCESS_KEY:?Set S3_SECRET_ACCESS_KEY in .env}"
: "${S3_MEDIA_BUCKET:=sova-media}"
: "${S3_REPORTS_BUCKET:=sova-reports}"
: "${GARAGE_CAPACITY:=20G}"
readonly GARAGE_KEY_NAME="sova-app"

garage() {
  "${COMPOSE[@]}" exec -T s3 /garage "$@"
}

echo "Waiting for Garage to become ready..."
for _ in $(seq 1 30); do
  if garage status >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
garage status

echo "Checking cluster layout..."
readonly NODE_ID="$(garage node id -q | cut -d'@' -f1 | tr -d '[:space:]')"
if garage status | grep -q "NO ROLE ASSIGNED"; then
  echo "Assigning single-node layout (capacity ${GARAGE_CAPACITY})..."
  garage layout assign -z dc1 -c "${GARAGE_CAPACITY}" "${NODE_ID}"
  garage layout apply --version 1
else
  echo "Layout already assigned, skipping."
fi

for bucket in "${S3_MEDIA_BUCKET}" "${S3_REPORTS_BUCKET}"; do
  if garage bucket info "${bucket}" >/dev/null 2>&1; then
    echo "Bucket ${bucket} already exists, skipping."
  else
    echo "Creating bucket ${bucket}..."
    garage bucket create "${bucket}"
  fi
done

if garage key info "${GARAGE_KEY_NAME}" >/dev/null 2>&1; then
  echo "Key ${GARAGE_KEY_NAME} already exists, skipping import."
else
  echo "Importing application key ${GARAGE_KEY_NAME}..."
  garage key import --yes -n "${GARAGE_KEY_NAME}" "${S3_ACCESS_KEY_ID}" "${S3_SECRET_ACCESS_KEY}"
fi

for bucket in "${S3_MEDIA_BUCKET}" "${S3_REPORTS_BUCKET}"; do
  echo "Granting ${GARAGE_KEY_NAME} read/write on ${bucket}..."
  garage bucket allow --read --write "${bucket}" --key "${GARAGE_KEY_NAME}"
done

echo "Garage bootstrap complete."
