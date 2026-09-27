#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "${PROJECT_DIR}"

[[ $# == 1 && "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Usage: scripts/tag-prod-release.sh vMAJOR.MINOR.PATCH" >&2
  exit 1
}
readonly TAG="$1"

"${PROJECT_DIR}/scripts/validate-release-prod.sh" >/dev/null
[[ "$(git branch --show-current)" == develop ]] || {
  echo "Switch to the infra develop branch before tagging production." >&2
  exit 1
}
git diff --quiet && git diff --cached --quiet || {
  echo "Commit all tracked changes before tagging production." >&2
  exit 1
}

git fetch --quiet origin develop
[[ "$(git rev-parse HEAD)" == "$(git rev-parse FETCH_HEAD)" ]] || {
  echo "Local develop must match origin/develop. Pull or push changes first." >&2
  exit 1
}

if git show-ref --verify --quiet "refs/tags/${TAG}"; then
  echo "The local tag ${TAG} already exists." >&2
  exit 1
fi
remote_tag="$(git ls-remote --tags origin "refs/tags/${TAG}")"
if [[ -n "${remote_tag}" ]]; then
  echo "The remote tag ${TAG} already exists." >&2
  exit 1
fi

git tag -a "${TAG}" -m "Production release ${TAG}"
if ! git push origin "refs/tags/${TAG}"; then
  git tag -d "${TAG}" >/dev/null
  echo "The push failed; the local tag was removed for a clean retry." >&2
  exit 1
fi
echo "Production release ${TAG} was pushed. Watch the Deploy production release workflow."
