#!/usr/bin/env bash

set -Eeuo pipefail

readonly KEYCLOAK_SERVER_URL="${KEYCLOAK_SERVER_URL:-http://localhost:8080}"
readonly KEYCLOAK_REALM="${KEYCLOAK_REALM:-sova}"
readonly KEYCLOAK_LOGIN_THEME="${KEYCLOAK_LOGIN_THEME:-sova}"
readonly KCADM_BIN="${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}"
readonly KCADM_CONFIG="/tmp/sova-theme-kcadm-$$.config"

required_variables=(
  KC_BOOTSTRAP_ADMIN_USERNAME
  KC_BOOTSTRAP_ADMIN_PASSWORD
)

for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "${variable_name} must be set to configure the Keycloak theme." >&2
    exit 1
  fi
done

cleanup() {
  rm -f -- "${KCADM_CONFIG}"
}
trap cleanup EXIT

"${KCADM_BIN}" config credentials \
  --config "${KCADM_CONFIG}" \
  --server "${KEYCLOAK_SERVER_URL}" \
  --realm master \
  --user "${KC_BOOTSTRAP_ADMIN_USERNAME}" \
  --password "${KC_BOOTSTRAP_ADMIN_PASSWORD}" \
  >/dev/null

"${KCADM_BIN}" update "realms/${KEYCLOAK_REALM}" \
  --config "${KCADM_CONFIG}" \
  --set "loginTheme=${KEYCLOAK_LOGIN_THEME}" \
  >/dev/null

echo "Keycloak login theme '${KEYCLOAK_LOGIN_THEME}' is active for realm '${KEYCLOAK_REALM}'."
