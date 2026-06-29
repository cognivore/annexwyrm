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
#   - nginx site /etc/nginx/sites-available/wyrm-fere (:80 acme+redirect, :443 -> unix socket,
#       PLUS `location /static/ { alias /opt/annexwyrm/static/; }` — the app has no
#       /static route, so without it every page renders unstyled)
#       PLUS `client_max_body_size 2048m;` + `client_body_timeout 1800s;` and, in
#       snippets/annexwyrm-proxy.conf, `proxy_read_timeout 1800s; proxy_send_timeout
#       1800s;` — large media uploads (kept in sync with the daemon's 2 GiB
#       MAX_REQ_BYTES); the synchronous rclone put to Drive can take minutes)
#   - certbot certonly --webroot -w /var/www/html -d wyrm.fere.me
#   - Porkbun A record wyrm.fere.me -> 46.62.199.15
#
# Data (/var/lib/annexwyrm) and secrets (/etc/annexwyrm) live OUTSIDE the
# rsync target, so --delete can never touch them.

HOST="root@chat.md110.se"
PROD="/opt/annexwyrm/"

echo "Syncing source -> $HOST:$PROD"
rsync -az --delete --filter="merge .rsync-filter" ./ "$HOST:$PROD"

# Apply the kk_bytes_join_with refcount-leak fix to the box's koka kklib.
# annexwyrm builds every HTML page (and JSON) with `.join(...)`, which lowers
# to kk_bytes_join_with — the stock kklib dup'd and leaked every joined string,
# so the long-running daemon grew unbounded per request. The fix is a runtime
# kklib patch (cognivore/koka bb9e2fba), independent of the koka compiler
# version; the nix build uses the fully-patched koka 3.2.7, but the box has a
# 3.2.3 BINARY install with no Haskell toolchain to rebuild from source, so we
# patch its kklib in place. Idempotent (skips if already applied); koka
# recompiles kklib from this source on every `rm -rf build/.koka` rebuild below.
echo "Ensuring kklib join-leak fix is applied on the server..."
ssh "$HOST" 'KK=$(ls -d /usr/local/share/koka/v*/kklib 2>/dev/null | head -1)
  if [ -z "$KK" ]; then echo "WARN: koka kklib dir not found; skipping join-leak patch"; \
  elif grep -q kk_vector_buf_borrow "$KK/src/bytes.c"; then echo "  kklib join-leak fix already present"; \
  else patch -p1 -d "$KK" < /opt/annexwyrm/nix/kklib-join-leak.patch && echo "  kklib join-leak fix applied"; fi'

echo "Building on the server (koka native)..."
# Build to a temp name and atomically rename over the live binary: the
# running daemon holds build/annexwyrm open, so koka's plain copy onto it
# fails with ETXTBSY ("could not copy file"). rename(2) replaces the
# directory entry while the running process keeps its old inode.
ssh "$HOST" 'cd /opt/annexwyrm && rm -rf build/.koka && \
  koka -O2 --target=c --include=src --ccincdir="$(pwd)/csrc" \
       --builddir=build/.koka --cclib="sqlite3;ssl;crypto;curl;argon2" \
       -o build/annexwyrm.new src/annexwyrm.kk && \
  chmod +x build/annexwyrm.new && strip build/annexwyrm.new && \
  mv -f build/annexwyrm.new build/annexwyrm'

echo "Restarting service..."
ssh "$HOST" 'systemctl restart annexwyrm && sleep 2 && systemctl is-active annexwyrm'

echo "Deployed: https://wyrm.fere.me/"
