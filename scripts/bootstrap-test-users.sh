#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${SEED_TEST_ACCOUNTS:-false}" != "true" ]]; then
  echo "Test account bootstrap is disabled."
  exit 0
fi

if [[ "${ENVIRONMENT:-}" != "development" ]]; then
  echo "Test accounts may only be bootstrapped in the development environment." >&2
  exit 1
fi

readonly KEYCLOAK_SERVER_URL="${KEYCLOAK_SERVER_URL:-http://keycloak:8080}"
readonly KEYCLOAK_REALM="${KEYCLOAK_REALM:-sova}"
readonly KCADM_BIN="${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}"
readonly KCADM_CONFIG="/tmp/sova-test-users-kcadm-$$.config"

required_variables=(
  KEYCLOAK_ADMIN_USERNAME
  KEYCLOAK_ADMIN_PASSWORD
  TEST_KAM_PASSWORD
  TEST_BOSS_PASSWORD
  TEST_ADMIN_PASSWORD
)

for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "${variable_name} must be set when SEED_TEST_ACCOUNTS=true." >&2
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
  --user "${KEYCLOAK_ADMIN_USERNAME}" \
  --password "${KEYCLOAK_ADMIN_PASSWORD}" \
  >/dev/null

upsert_user() {
  local username=$1
  local first_name=$2
  local last_name=$3
  local email=$4
  local password=$5
  local user_id

  user_id="$(
    "${KCADM_BIN}" get users \
      --config "${KCADM_CONFIG}" \
      --target-realm "${KEYCLOAK_REALM}" \
      --query exact=true \
      --query "username=${username}" \
      --fields id \
      --format csv \
      --noquotes
  )"

  if [[ "${user_id}" == *$'\n'* ]]; then
    echo "More than one Keycloak user matched username ${username}." >&2
    exit 1
  fi

  if [[ -z "${user_id}" ]]; then
    "${KCADM_BIN}" create users \
      --config "${KCADM_CONFIG}" \
      --target-realm "${KEYCLOAK_REALM}" \
      --set "username=${username}" \
      --set enabled=true \
      --set "firstName=${first_name}" \
      --set "lastName=${last_name}" \
      --set "email=${email}" \
      --set emailVerified=true \
      --set 'requiredActions=[]' \
      >/dev/null
    echo "Created Keycloak test user ${username}."
  else
    "${KCADM_BIN}" update "users/${user_id}" \
      --config "${KCADM_CONFIG}" \
      --target-realm "${KEYCLOAK_REALM}" \
      --set enabled=true \
      --set "firstName=${first_name}" \
      --set "lastName=${last_name}" \
      --set "email=${email}" \
      --set emailVerified=true \
      --set 'requiredActions=[]' \
      >/dev/null
    echo "Updated Keycloak test user ${username}."
  fi

  "${KCADM_BIN}" set-password \
    --config "${KCADM_CONFIG}" \
    --target-realm "${KEYCLOAK_REALM}" \
    --username "${username}" \
    --new-password "${password}"
}

upsert_user \
  "test-kam" \
  "Тестовый" \
  "КАМ" \
  "kam@1uup.ru" \
  "${TEST_KAM_PASSWORD}"

upsert_user \
  "test-boss" \
  "Тестовый" \
  "Руководитель" \
  "boss@1uup.ru" \
  "${TEST_BOSS_PASSWORD}"

upsert_user \
  "test-admin" \
  "Тестовый" \
  "Администратор" \
  "admin_platform@1uup.ru" \
  "${TEST_ADMIN_PASSWORD}"

echo "Keycloak test accounts are ready."
