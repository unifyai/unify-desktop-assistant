#!/usr/bin/env bash
set -euo pipefail

# Check and install cloudflared if missing
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[tunnel] cloudflared not found. Installing..."
  # Add cloudflare GPG key and apt source
  mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
  apt-get update
  apt-get install -y cloudflared
  echo "[tunnel] cloudflared installed."
else
  echo "[tunnel] cloudflared is already installed: $(cloudflared --version | head -n1)"
fi

# Configure a named tunnel to forward localhost:3000 to a custom domain
# Usage: TUNNEL_HOSTNAME=myapp.example.com TUNNEL_NAME=myapp bash tunnel.sh

HOSTNAME="${TUNNEL_HOSTNAME:-${1:-}}"
TUNNEL_NAME="${TUNNEL_NAME:-${2:-myapp}}"
CF_DIR="$HOME/.cloudflared"
UNIFY_BASE_URL="${UNIFY_BASE_URL:-https://api.unify.ai/v0}"
LOCAL_PORT=3000

# Optional env for Unify logging
# UNIFY_KEY        → API key for auth (Bearer)
# ASSISTANT_NAME   → Full name: "First Last"

ASSISTANT_ID=""

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then return 0; fi
  echo "[tunnel] 'jq' not found. Installing via apt..." >&2
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y jq >/dev/null 2>&1 || true
  if ! command -v jq >/dev/null 2>&1; then
    echo "[tunnel] WARNING: Failed to install 'jq'. Skipping Unify logging." >&2
    return 1
  fi
}

log_url_to_unify() {
  url_to_log="$1"
  if [[ -z "${UNIFY_KEY:-}" || -z "${ASSISTANT_NAME:-}" ]]; then
    return 0
  fi
  if ! ensure_jq; then
    return 0
  fi

  echo "[tunnel] Logging URL to Unify for assistant '${ASSISTANT_NAME}'..."

  # List assistants with status capture
  list_file="/tmp/unify_assistants_list.json"
  http_list=$(curl -sS -o "$list_file" -w "%{http_code}" -H "Authorization: Bearer ${UNIFY_KEY}" "${UNIFY_BASE_URL}/assistant" || true)
  if [[ "$http_list" != "200" ]]; then
    echo "[tunnel] WARNING: Assistants list returned HTTP $http_list; skipping log." >&2
    return 0
  fi
  list_json=$(cat "$list_file" 2>/dev/null || echo '')
  if [[ -z "$list_json" ]]; then
    echo "[tunnel] WARNING: Empty response from assistants list; skipping log." >&2
    return 0
  fi

  # Match assistant by full name (case-insensitive)
  ids=$(echo "$list_json" | jq -r --arg name "${ASSISTANT_NAME}" '((.info // [])[] | select((((.first_name // "") + " " + (.surname // "")) | ascii_downcase) == ($name | ascii_downcase)) | .agent_id) // empty' 2>/dev/null | sed '/^null$/d' || true)
  if [[ -z "$ids" ]]; then
    echo "[tunnel] WARNING: No assistant matched name '${ASSISTANT_NAME}'." >&2
    return 0
  fi
  count=$(printf '%s\n' "$ids" | grep -c . || true)
  if (( count > 1 )); then
    echo "[tunnel] WARNING: Multiple assistants matched name '${ASSISTANT_NAME}'." >&2
    return 0
  fi
  assistant_id="$(printf '%s\n' "$ids" | head -n1)"
  if [[ -z "$assistant_id" ]]; then
    echo "[tunnel] WARNING: Matched assistant has empty id; skipping." >&2
    return 0
  fi

  ASSISTANT_ID="$assistant_id"

  # Patch desktop_url
  payload=$(jq -n --arg url "$url_to_log" '{desktop_url: $url}')
  http_code=$(curl -sS -o /tmp/unify_patch_resp.json -w "%{http_code}" \
    -X PATCH \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${UNIFY_KEY}" \
    -d "$payload" \
    "${UNIFY_BASE_URL}/assistant/${assistant_id}/config" || true)
  if [[ "$http_code" != "200" ]]; then
    echo "[tunnel] WARNING: Failed to update assistant (HTTP $http_code)." >&2
  else
    echo "[tunnel] Updated assistant ${assistant_id} desktop_url → ${url_to_log}"
  fi
}

clear_url_in_unify() {
  if [[ -z "${UNIFY_KEY:-}" || -z "${ASSISTANT_NAME:-}" ]]; then
    return 0
  fi
  if ! ensure_jq; then
    return 0
  fi

  if [[ -z "$ASSISTANT_ID" ]]; then
    list_file="/tmp/unify_assistants_list.json"
    http_list=$(curl -sS -o "$list_file" -w "%{http_code}" -H "Authorization: Bearer ${UNIFY_KEY}" "${UNIFY_BASE_URL}/assistant" || true)
    if [[ "$http_list" != "200" ]]; then
      return 0
    fi
    list_json=$(cat "$list_file" 2>/dev/null || echo '')
    ids=$(echo "$list_json" | jq -r --arg name "${ASSISTANT_NAME}" '((.info // [])[] | select((((.first_name // "") + " " + (.surname // "")) | ascii_downcase) == ($name | ascii_downcase)) | .agent_id) // empty' 2>/dev/null | sed '/^null$/d' || true)
    count=$(printf '%s\n' "$ids" | grep -c . || true)
    if (( count != 1 )); then
      return 0
    fi
    ASSISTANT_ID="$(printf '%s\n' "$ids" | head -n1)"
  fi

  payload='{"desktop_url":""}'
  curl -sS -o /dev/null -w "%{http_code}" \
    -X PATCH \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${UNIFY_KEY}" \
    -d "$payload" \
    "${UNIFY_BASE_URL}/assistant/${ASSISTANT_ID}/config" >/dev/null 2>&1 || true
}

if [ -z "$HOSTNAME" ]; then
  echo "[tunnel] INFO: No hostname provided. Starting ad-hoc tunnel for testing..."

  CF_PID=""
  cleanup() {
    echo "\n[tunnel] Shutting down tunnel..."
    if [ -n "$CF_PID" ] && kill -0 "$CF_PID" 2>/dev/null; then
      kill "$CF_PID" 2>/dev/null || true
      sleep 0.5
      if kill -0 "$CF_PID" 2>/dev/null; then
        kill -9 "$CF_PID" 2>/dev/null || true
      fi
    fi
    clear_url_in_unify || true
  }
  trap cleanup INT TERM EXIT

  LOG_FILE="/tmp/trycloudflare_${LOCAL_PORT}.log"
  : > "$LOG_FILE"

  set +e
  cloudflared tunnel --url "http://localhost:${LOCAL_PORT}" 2>&1 | tee "$LOG_FILE" &
  CF_PID=$!
  set -e

  tries=20
  url=""
  while [ $tries -gt 0 ]; do
    tries=$((tries-1))
    if grep -Eo 'https://[a-zA-Z0-9.-]+trycloudflare\.com' "$LOG_FILE" >/dev/null 2>&1; then
      url=$(grep -Eo 'https://[a-zA-Z0-9.-]+trycloudflare\.com' "$LOG_FILE" | head -n1)
      break
    fi
    if grep -Eo 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$LOG_FILE" >/dev/null 2>&1; then
      url=$(grep -Eo 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$LOG_FILE" | head -n1)
      break
    fi
    sleep 0.3
  done

  if [ -n "$url" ]; then
    echo "[tunnel] Public URL: $url"
    log_url_to_unify "$url"
  else
    echo "[tunnel] Waiting for public URL... check logs: $LOG_FILE"
  fi

  wait "$CF_PID" || true
  exit 0
fi

if [ ! -f "$CF_DIR/cert.pem" ]; then
  echo "[tunnel] ERROR: cloudflared is not logged in. Run: cloudflared tunnel login" >&2
  exit 1
fi

# Create tunnel if missing
credentials_file=""
if cloudflared tunnel info "$TUNNEL_NAME" >/dev/null 2>&1; then
  credentials_file=$(ls -t "$CF_DIR"/*.json 2>/dev/null | head -n1 || true)
else
  echo "[tunnel] Creating tunnel '$TUNNEL_NAME'..."
  create_out=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1 | tee /dev/stderr)
  credentials_file=$(echo "$create_out" | grep -oE "$CF_DIR/[a-f0-9-]+\.json" | head -n1 || true)
  if [ -z "$credentials_file" ]; then
    credentials_file=$(ls -t "$CF_DIR"/*.json 2>/dev/null | head -n1 || true)
  fi
fi

if [ -z "$credentials_file" ]; then
  echo "[tunnel] ERROR: Could not find tunnel credentials in $CF_DIR" >&2
  exit 1
fi

# Write config mapping hostname → localhost:3000
cat > "$CF_DIR/config.yml" <<EOF
tunnel: $TUNNEL_NAME
credentials-file: $credentials_file
ingress:
  - hostname: $HOSTNAME
    service: http://localhost:3000
  - service: http_status:404
EOF

# Route DNS (creates proxied CNAME)
cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME" || true

echo "[tunnel] Running tunnel '$TUNNEL_NAME' for https://$HOSTNAME → http://localhost:3000"

CF_PID=""
cleanup_named() {
  echo "\n[tunnel] Shutting down named tunnel..."
  if [ -n "$CF_PID" ] && kill -0 "$CF_PID" 2>/dev/null; then
    kill "$CF_PID" 2>/dev/null || true
    sleep 0.5
    if kill -0 "$CF_PID" 2>/dev/null; then
      kill -9 "$CF_PID" 2>/dev/null || true
    fi
  fi
  # Log hostname URL at start and clear on cleanup
  clear_url_in_unify || true
}
trap cleanup_named INT TERM EXIT

# Log the hostname URL at start (best-effort)
if [ -n "${UNIFY_KEY:-}" ] && [ -n "${ASSISTANT_NAME:-}" ]; then
  log_url_to_unify "https://${HOSTNAME}"
fi

cloudflared tunnel run "$TUNNEL_NAME" &
CF_PID=$!
wait "$CF_PID" || true


