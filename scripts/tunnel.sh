#!/bin/bash
set -euo pipefail

LOG=/tmp/tunnel.log
REPO=~/projet/juice-shop

echo "Lancement du tunnel..."
: > "$LOG"
cloudflared tunnel --url http://localhost:8080 > "$LOG" 2>&1 &
TUNNEL_PID=$!
echo "PID : $TUNNEL_PID"

URL=""
for i in $(seq 1 30); do
  URL=$(grep -o 'https://[a-z0-9-]\+\.trycloudflare\.com' "$LOG" | head -1 || true)
  [ -n "$URL" ] && break
  sleep 1
done

if [ -z "$URL" ]; then
  echo "URL introuvable apres 30 s. Contenu du log :"
  cat "$LOG"
  kill "$TUNNEL_PID"
  exit 1
fi

echo "Tunnel actif : $URL"
cd "$REPO"
gh secret set DEFECTDOJO_URL --body "$URL"
echo "Secret DEFECTDOJO_URL mis a jour."
echo "Pour arreter le tunnel : kill $TUNNEL_PID"
