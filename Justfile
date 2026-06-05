# annexwyrm — declarative task runner. Everything that touches the
# codebase has a `just` recipe. Nothing is built outside Nix.

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# --- Build ------------------------------------------------------------

# Fully sandboxed, reproducible nix build into ./result/bin/annexwyrm.
nix-build:
    nix build .#default
    @echo "built: ./result/bin/annexwyrm"

# Iterative dev build: invokes koka directly against the dev-shell
# environment (assumes you're inside `nix develop` / direnv).  Faster
# than `nix-build` because koka caches under build/.koka.
build:
    mkdir -p build
    koka -O2 --target=c \
      --include=src \
      --ccincdir="$(pwd)/csrc" \
      --builddir=build/.koka \
      --cclib="sqlite3;ssl;crypto;curl;argon2" \
      -o build/annexwyrm \
      src/annexwyrm.kk
    @echo "built: ./build/annexwyrm"

# Type-check without producing a binary.
check:
    koka --target=c \
      --include=src \
      --ccincdir="$(pwd)/csrc" \
      -c \
      src/annexwyrm.kk

# --- Run --------------------------------------------------------------

# Initialise the data dir (schema + actor keypair).
# `ANNEXWYRM_DATA` defaults to ./data.
init:
    mkdir -p "${ANNEXWYRM_DATA:-./data}"
    ./build/annexwyrm init "${ANNEXWYRM_DATA:-./data}"

# Start the daemon. Caddy must be run separately (see `just caddy`).
serve:
    ANNEXWYRM_SOCKET="${ANNEXWYRM_SOCKET:-/tmp/annexwyrm.sock}" \
    ANNEXWYRM_DATA="${ANNEXWYRM_DATA:-./data}" \
    ./build/annexwyrm serve

# Run Caddy in front of the daemon using Caddyfile.example. Edit it
# first to set your domain and adjust the socket path.
caddy:
    caddy run --config Caddyfile.example

# Print the local actor JSON-LD (for debugging federation).
dump-actor:
    ANNEXWYRM_DATA="${ANNEXWYRM_DATA:-./data}" \
    ./build/annexwyrm dump-actor

# --- Inspection -------------------------------------------------------

# Drop into a sqlite3 shell against the data dir's database.
db:
    sqlite3 "${ANNEXWYRM_DATA:-./data}/annexwyrm.db"

# Show the C that Koka generates from a single module (debug FFI).
show-c MODULE='annexwyrm':
    koka --showc -c \
      --include=src \
      --include=csrc \
      --builddir=build/.koka-showc \
      src/{{MODULE}}.kk

# --- E2E tests --------------------------------------------------------

# Run the end-to-end test against a fresh local daemon (no gdrive).
test-e2e:
    bash tests/e2e/run.sh

# Run the Caddy-fronted end-to-end test: starts an ISOLATED Caddy on a
# probed-free TCP port (its own admin port, never the user's :2019) in front
# of a temp-socket daemon, and drives the full journey over http://127.0.0.1.
# Catches the four reverse-proxy bugs (static 404, invalid Caddyfile, wrong
# init identity, Secure cookie over http) that run.sh cannot see.
test-e2e-caddy:
    bash tests/e2e/run-caddy.sh

# Same, but also push uploads to gdrive:annexwyrm-test/ via rclone.
# Requires `gdrive` to be a working rclone remote in ~/.config/rclone/rclone.conf.
test-e2e-gdrive:
    ANNEXWYRM_E2E_GDRIVE=1 bash tests/e2e/run.sh

# --- Hygiene ----------------------------------------------------------

clean:
    rm -rf build .koka result result-*
