#!/usr/bin/env bash
set -Eeuo pipefail

readonly RELEASE_FILE="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/release.prod.env}"
[[ -f "${RELEASE_FILE}" ]] || { echo "Missing ${RELEASE_FILE}." >&2; exit 1; }

for name in FRONTEND_TAG BACKEND_TAG; do
  count="$(grep -c "^${name}=" "${RELEASE_FILE}" || true)"
  if [[ "${count}" != 1 ]]; then
    echo "${name} must appear exactly once in ${RELEASE_FILE}." >&2
    exit 1
  fi
  value="$(sed -n "s/^${name}=//p" "${RELEASE_FILE}")"
  if [[ ! "${value}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${name} must be a published release tag such as v1.2.3." >&2
    exit 1
  fi
  echo "${name}=${value}"
done
