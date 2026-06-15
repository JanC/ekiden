#!/usr/bin/env bash
set -euo pipefail

# Generates a token for managing self-hosted runners, authenticating as a
# GitHub App: JWT -> installation access token -> (optional) registration token.
#
# GH_TOKEN_KIND controls what is printed on stdout:
#   registration (default) - registration token, used by runners to enroll.
#   installation           - installation access token (~1h), used to call the
#                            Actions API directly (list / delete runners, ...).
#
# Requirements: openssl, curl, jq

# Configuration is read from the environment (see host/.env.example):
APP_ID="${GITHUB_APP_ID:-}"                       # GitHub App ID (numeric)
PRIVATE_KEY_PATH="${GITHUB_APP_PRIVATE_KEY_PATH:-}"  # path to App .pem private key
OWNER="${GITHUB_OWNER:-}"
REPO="${GITHUB_REPO:-}"   # optional: set for a repo-level runner, leave empty for an org-level runner
TOKEN_KIND="${GH_TOKEN_KIND:-registration}"

API="https://api.github.com"

# stdout is reserved for the token (captured by launch.sh), so logs go to stderr.
log() { echo "$(date "+%Y/%m/%d %H:%M:%S") [HOST] $1" >&2; }

for var in GITHUB_APP_ID GITHUB_APP_PRIVATE_KEY_PATH GITHUB_OWNER; do
  [ -n "${!var:-}" ] || { log "❌ Missing required env var: $var"; exit 1; }
done

# Repo scope when GITHUB_REPO is set, org scope otherwise.
if [ -n "$REPO" ]; then
  SCOPE="repos/${OWNER}/${REPO}"
else
  SCOPE="orgs/${OWNER}"
fi

for cmd in openssl curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { log "❌ Missing dependency: $cmd"; exit 1; }
done
[ -r "$PRIVATE_KEY_PATH" ] || { log "❌ Cannot read private key: $PRIVATE_KEY_PATH"; exit 1; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# gh_api <step-label> <curl-args...>
# Runs the request, captures body + HTTP status. On non-2xx prints the step,
# status, and GitHub's error message, then exits. Echoes body on success.
gh_api() {
  local label="$1"; shift
  local resp http body
  resp=$(curl -sS -w $'\n%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@")
  http="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [ "$http" -lt 200 ] || [ "$http" -ge 300 ]; then
    log "❌ ${label} failed (HTTP $http): $(echo "$body" | jq -r '.message // empty' 2>/dev/null || echo "$body")"
    exit 1
  fi
  printf '%s' "$body"
}

# --- 1. Build and sign the JWT (RS256) ---
now=$(date +%s)
iat=$((now - 60))      # backdate 60s to tolerate clock skew
exp=$((now + 540))     # max 10 min; use 9 min

header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$APP_ID" | b64url)
unsigned="${header}.${payload}"

signature=$(printf '%s' "$unsigned" \
  | openssl dgst -sha256 -sign "$PRIVATE_KEY_PATH" \
  | b64url)

jwt="${unsigned}.${signature}"

# --- 2. Find the installation id for this scope ---
installation_id=$(gh_api "installation lookup" \
  -H "Authorization: Bearer ${jwt}" \
  "${API}/${SCOPE}/installation" \
  | jq -r '.id')

[ -n "$installation_id" ] && [ "$installation_id" != "null" ] \
  || { log "❌ Could not resolve installation id (is the App installed on ${SCOPE}?)"; exit 1; }

# --- 3. Exchange JWT for an installation access token ---
installation_token=$(gh_api "installation token" -X POST \
  -H "Authorization: Bearer ${jwt}" \
  "${API}/app/installations/${installation_id}/access_tokens" \
  | jq -r '.token')

[ -n "$installation_token" ] && [ "$installation_token" != "null" ] \
  || { log "❌ Failed to obtain installation access token"; exit 1; }

case "$TOKEN_KIND" in
  installation)
    printf '%s\n' "$installation_token"
    ;;
  registration)
    # Requires the App to have Administration: Read and write (repo scope) or
    # Organization self-hosted runners: Read and write (org scope).
    gh_api "registration token" -X POST \
      -H "Authorization: Bearer ${installation_token}" \
      "${API}/${SCOPE}/actions/runners/registration-token" \
      | jq -r '.token'
    ;;
  *)
    log "❌ Unknown GH_TOKEN_KIND: $TOKEN_KIND (expected installation or registration)"
    exit 1
    ;;
esac
