#!/bin/bash
#
# Generates a fresh JWT_SECRET and derives matching ANON_KEY / SERVICE_ROLE_KEY
# JWTs, so a new environment doesn't have to share the demo keys baked into
# .env.example. Mirrors the approach used in Supabase's own self-hosting
# template (utils/generate-keys.sh).
#
# Usage: ./utils/generate-keys.sh
# Prints KEY=value lines to stdout - review them, then paste into your .env.
# This does not modify any files itself.

set -euo pipefail

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

sign() {
  local secret="$1" data="$2"
  printf '%s' "$data" | openssl dgst -sha256 -hmac "$secret" -binary | b64url
}

make_jwt() {
  local secret="$1" role="$2" iat="$3" exp="$4"
  local header payload signature
  header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$role" "$iat" "$exp" | b64url)
  signature=$(sign "$secret" "${header}.${payload}")
  printf '%s.%s.%s' "$header" "$payload" "$signature"
}

JWT_SECRET=$(openssl rand -hex 32)
IAT=$(date +%s)
EXP=$((IAT + 10 * 365 * 24 * 60 * 60)) # ~10 years

ANON_KEY=$(make_jwt "$JWT_SECRET" "anon" "$IAT" "$EXP")
SERVICE_ROLE_KEY=$(make_jwt "$JWT_SECRET" "service_role" "$IAT" "$EXP")

echo "JWT_SECRET=$JWT_SECRET"
echo "ANON_KEY=$ANON_KEY"
echo "SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY"
