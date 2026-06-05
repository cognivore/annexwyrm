#!/usr/bin/env bash
set -euo pipefail
#
# Deploy annexwyrm to permanent production at https://wyrm.fere.me on
# chat.md110.se. Mirrors north-london-cube-community/deploy.sh (rsync source
# to /opt, build + restart on the box) — but annexwyrm is a Koka→C binary, so
# it builds NATIVELY on the server (koka 3.2.3 + apt libsqlite3/ssl/curl/
# argon2), not via pnpm.
#
# One-time server setup (already done; documented here so it's reproducible):
#   - apt-get install build-essential pkg-config libsqlite3-dev libssl-dev \
#       libcurl4-openssl-dev libargon2-dev sqlite3 rsync
#   - install koka 3.2.3 linux-x64 to /usr/local
#   - /etc/annexwyrm/env  -> ANNEXWYRM_PASSWORD=<rageveil annexwyrm.localhost/sweater/password> (root,600)
#   - /etc/systemd/system/annexwyrm.service (serve on /run/annexwyrm/sock; ExecStartPre runs init)
#   - nginx site /etc/nginx/sites-available/wyrm-fere (:80 acme+redirect, :443 -> unix socket)
#   - certbot certonly --webroot -w /var/www/html -d wyrm.fere.me
#   - Porkbun A record wyrm.fere.me -> 46.62.199.15
#
# Data (/var/lib/annexwyrm) and secrets (/etc/annexwyrm) live OUTSIDE the
# rsync target, so --delete can never touch them.

HOST="root@chat.md110.se"
PROD="/opt/annexwyrm/"

echo "Syncing source -> $HOST:$PROD"
rsync -az --delete --filter="merge .rsync-filter" ./ "$HOST:$PROD"

echo "Building on the server (koka native)..."
ssh "$HOST" 'cd /opt/annexwyrm && rm -rf build/.koka && \
  koka -O2 --target=c --include=src --ccincdir="$(pwd)/csrc" \
       --builddir=build/.koka --cclib="sqlite3;ssl;crypto;curl;argon2" \
       -o build/annexwyrm src/annexwyrm.kk && \
  chmod +x build/annexwyrm && strip build/annexwyrm'

echo "Restarting service..."
ssh "$HOST" 'systemctl restart annexwyrm && sleep 2 && systemctl is-active annexwyrm'

echo "Deployed: https://wyrm.fere.me/"
