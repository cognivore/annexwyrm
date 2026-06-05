#!/usr/bin/env bash
# tests/e2e/run-federation.sh — two-instance ActivityPub S2S federation test.
#
# This is the FIRST real federation system test: two live annexwyrm daemons,
# each behind its OWN isolated Caddy, talking ActivityPub server-to-server over
# HTTP, with the delivery queue actually draining a signed POST from one
# instance's outbox into the other's inbox.
#
# It is implemented STRICTLY against tests/e2e/SPEC-federation.md. Read that
# file alongside this one: every step here maps to a §5 step there, and every
# FINDING (§6) that shaped a design choice is cited at its seam.
#
# THE JOURNEY (SPEC §1):
#   F1  A logs in, then A follows B (via POST /follow — never the CLI; FINDING 1).
#   F2  A's Follow is delivered to B; B auto-accepts and queues an Accept to A.
#   F3  B's Accept is delivered to A; A's follow row flips to accepted.
#       → A is now an accepted follower of B as seen from BOTH sides.
#   F4  B uploads a public item, then publishes it → one Create fanned to A
#       (recipients=1, the headline proving the whole handshake mattered).
#   F5  The drain delivers the signed Create to A; A persists the remote
#       activity (NOT an item row — FINDING 9); delivery goes pending→success
#       with attempts=0 (retry/backoff never touched — FINDING 7).
#   F6  Negative controls: dedup (inbox/duplicate) and unsigned rejection (401).
#
# TWO TIERS (SPEC §0, FINDING 10):
#   Tier 1 (the real S2S wire test) drives delivery with the binary's own
#          `drain` subcommand — a one-shot that drains the delivery queue,
#          signing + POSTing each row, then exits. The daemon's own delivery
#          machinery runs a real signed HTTP POST. THIS IS THE TEST WE WANT.
#   Tier 0 (fallback) curl-replays the exact signed bytes a drain would send,
#          driving only the RECEIVER's real inbound pipeline. Used only if the
#          `drain` subcommand is absent from the binary under test.
# The test auto-detects which tier is available and ANNOUNCES it loudly, so a
# green run is never silently the weaker tier.
#
#   NOTE ON `drain` INVOCATION (deviates from SPEC Appendix B): the binary's
#   actual `drain` subcommand takes NO data-dir argument — it reads
#   ANNEXWYRM_DATA from the environment — and prints a BARE integer (the count
#   processed), not the string "drained N". This script invokes it as
#   `ANNEXWYRM_DATA=$I_DATA … "$BINARY" drain` and parses the bare count. The
#   spec's "drained 1 / mentions 1" assertions are honoured by asserting the
#   printed count equals 1.
#
# Usage:
#     nix develop -c bash tests/e2e/run-federation.sh
#     KEEP_TMP=1 nix develop -c bash tests/e2e/run-federation.sh   # leave $TMP
#     ANNEXWYRM_BINARY=/path nix develop -c bash tests/e2e/run-federation.sh
#     FED_FORCE_TIER0=1 …      # force the fallback tier even if `drain` exists

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS_DIR/../.." && pwd)"

# shellcheck source=./lib.sh
. "$THIS_DIR/lib.sh"

# ===========================================================================
#  Identity fixtures (SPEC §3). Set once, reused everywhere. Two of every-
#  thing; namespaced A_/B_ relentlessly.
#
#  A is "the follower / the publisher's audience" (ayla).
#  B is "the publisher" (belgarath).
#
#  Both instances share the host 127.0.0.1 and differ ONLY by port, so the
#  PORT disambiguates in every assertion — we never assert on host alone.
# ===========================================================================
A_USER="ayla";       A_DOMAIN="127.0.0.1"
B_USER="belgarath";  B_DOMAIN="127.0.0.1"
A_PASS="fed-e2e-A";  B_PASS="fed-e2e-B"
A_INSTANCE="ayla's annexwyrm (fed e2e A)"
B_INSTANCE="belgarath's annexwyrm (fed e2e B)"

# ===========================================================================
#  §3.4 base-URL / port coherence (the linchpin; SPEC §1 & FINDING 5).
#
#  init mints every id and inbox URL from ANNEXWYRM_BASE_URL. When B publishes,
#  B's Create carries actor=$B_ACTOR; when A receives it, A's signature path
#  FETCHES that actor URL with libcurl. csrc/curl_bridge.c sets
#  CURLOPT_FOLLOWLOCATION=0 and sends NO Host override — it hits whatever host
#  is literally in the URL. So every minted id MUST be directly fetchable AS
#  WRITTEN. Setting each instance's base URL to http://127.0.0.1:$PORT makes
#  ids self-resolving cross-instance with zero DNS or Host-header trickery,
#  and lets each Caddy site block be keyed on 127.0.0.1:$PORT directly. A plain
#  `curl http://127.0.0.1:$PORT/...` then matches — no Host: gymnastics, unlike
#  run-caddy.sh (which uses a hostname base URL + Host header for transport
#  only because it never fetches its own absolute ids cross-process).
# ===========================================================================

# ===========================================================================
#  Temp layout + four free ephemeral ports (SPEC §2). Never hardcode.
# ===========================================================================
TMP="$(mktemp -d -t annexwyrm-fed-e2e.XXXXXX)"

A_DATA="$TMP/A/data";  B_DATA="$TMP/B/data"
A_SOCK="$TMP/A/sock";  B_SOCK="$TMP/B/sock"
A_DAEMON_LOG="$TMP/A/daemon.log";  B_DAEMON_LOG="$TMP/B/daemon.log"
A_CADDYFILE="$TMP/A/Caddyfile";    B_CADDYFILE="$TMP/B/Caddyfile"
A_CADDY_RUN_LOG="$TMP/A/caddy.run.log"; B_CADDY_RUN_LOG="$TMP/B/caddy.run.log"
A_CADDY_ACCESS_LOG="$TMP/A/caddy.log";  B_CADDY_ACCESS_LOG="$TMP/B/caddy.log"
A_JAR="$TMP/A/cookies";  B_JAR="$TMP/B/cookies"
A_DB="$A_DATA/annexwyrm.db";  B_DB="$B_DATA/annexwyrm.db"

mkdir -p "$A_DATA" "$B_DATA"

# Probe four free ephemeral TCP ports on 127.0.0.1: a site + admin port each,
# so neither Caddy ever touches the user's :2019 admin. (Probe from run-caddy.)
free_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}
A_PORT="$(free_port)";  A_ADMIN="$(free_port)"
B_PORT="$(free_port)";  B_ADMIN="$(free_port)"

A_BASE="http://127.0.0.1:$A_PORT"
B_BASE="http://127.0.0.1:$B_PORT"
A_ACTOR="$A_BASE/users/$A_USER"
B_ACTOR="$B_BASE/users/$B_USER"
A_INBOX="$A_ACTOR/inbox"
B_INBOX="$B_ACTOR/inbox"
# S2S delivery target is the recipient's SHARED inbox, NOT the personal one.
# Every actor sets shared-inbox = base-url ++ "/inbox" (src/ap/actor.kk:58), and
# both lookup-actor-inbox and resolve-recipients return COALESCE(shared_inbox,
# inbox) (src/ap/persist.kk:54-66). When A caches B as a remote actor, B's
# parsed endpoints.sharedInbox (= $B_BASE/inbox) lands in actor.shared_inbox, so
# every delivery to B targets $B_BASE/inbox and is handled by handle-shared-inbox
# at POST /inbox (src/web/route.kk:59). The personal $X_INBOX (the actor.inbox
# column) is the actor-identity inbox and stays correct for SELECT inbox FROM
# actor assertions ONLY — never for delivery targets.
A_SHARED_INBOX="$A_BASE/inbox"
B_SHARED_INBOX="$B_BASE/inbox"

note "tmp dir:        $TMP"
note "A  ayla:        base=$A_BASE  port=$A_PORT  admin=$A_ADMIN"
note "B  belgarath:   base=$B_BASE  port=$B_PORT  admin=$B_ADMIN"
note "A actor:        $A_ACTOR"
note "B actor:        $B_ACTOR"

# ===========================================================================
#  Cleanup: kill BOTH daemons AND BOTH Caddys, dump ALL FOUR logs (+ both
#  access logs) on failure, rm temp dir unless KEEP_TMP=1 (SPEC §2, §7).
# ===========================================================================
A_DAEMON_PID="";  B_DAEMON_PID=""
A_CADDY_PID="";   B_CADDY_PID=""

dump_logs() {
    yellow "----- A daemon.log -----"
    [ -f "$A_DAEMON_LOG" ] && cat "$A_DAEMON_LOG" >&2 || true
    yellow "----- A caddy.run.log -----"
    [ -f "$A_CADDY_RUN_LOG" ] && cat "$A_CADDY_RUN_LOG" >&2 || true
    if [ -f "$A_CADDY_ACCESS_LOG" ] && [ -s "$A_CADDY_ACCESS_LOG" ]; then
        yellow "----- A caddy.log (access) -----"
        cat "$A_CADDY_ACCESS_LOG" >&2 || true
    fi
    yellow "----- B daemon.log -----"
    [ -f "$B_DAEMON_LOG" ] && cat "$B_DAEMON_LOG" >&2 || true
    yellow "----- B caddy.run.log -----"
    [ -f "$B_CADDY_RUN_LOG" ] && cat "$B_CADDY_RUN_LOG" >&2 || true
    if [ -f "$B_CADDY_ACCESS_LOG" ] && [ -s "$B_CADDY_ACCESS_LOG" ]; then
        yellow "----- B caddy.log (access) -----"
        cat "$B_CADDY_ACCESS_LOG" >&2 || true
    fi
}

kill_pid() {
    local pid="$1"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

cleanup() {
    local rc=$?
    if [ "$rc" != "0" ]; then
        red "run-federation.sh failed (exit $rc) — dumping all four logs"
        dump_logs
    fi
    # Kill all four processes, wait on each. A leaked Caddy/daemon on a temp
    # port is itself a test bug (SPEC §7).
    kill_pid "$A_CADDY_PID"
    kill_pid "$B_CADDY_PID"
    kill_pid "$A_DAEMON_PID"
    kill_pid "$B_DAEMON_PID"
    if [ "${KEEP_TMP:-0}" != "1" ]; then
        rm -rf "$TMP"
    else
        yellow "KEEP_TMP=1 → leaving $TMP for inspection"
    fi
}
trap cleanup EXIT INT TERM

# ===========================================================================
#  Per-instance helpers (SPEC §4.2). lib.sh's caddy_curl reads a single global
#  CADDY_BASE/CADDY_HOST; we talk to two bases, so we curl FULL URLs and never
#  rely on that global. No Host trickery: each site block is keyed on
#  127.0.0.1:$PORT and our ids use that authority, so a plain curl matches.
# ===========================================================================
a_curl() { curl --silent --show-error "$@"; }
b_curl() { curl --silent --show-error "$@"; }

# assert_status_url URL EXPECTED [LABEL] — GET a full URL, compare status.
# (The 2-arg-plus-label twin of lib.sh's assert_status_tcp, but URL-keyed.)
assert_status_url() {
    local url="$1" expected="$2" label="${3:-$url}"
    local code
    code=$(curl --silent --output /dev/null --max-time 10 \
                --write-out '%{http_code}' "$url" || true)
    if [ "$code" != "$expected" ]; then
        red "status assertion failed: $label"
        red "  url:      $url"
        red "  expected: $expected"
        red "  observed: $code"
        return 1
    fi
    green "  ✓ $label → $code"
}

# assert_sql_i DB SQL EXPECTED LABEL — scalar query against a named DB,
# compared exactly, with full failure ergonomics (SPEC §7). The two DB paths
# ($A_DB / $B_DB) make this the per-instance twin of lib.sh's assert_sql.
assert_sql_i() {
    local db="$1" sql="$2" expected="$3" label="${4:-sql}"
    local got
    got=$(sqlite3 "$db" "$sql" || true)
    if [ "$got" != "$expected" ]; then
        red "SQL assertion failed: $label"
        red "  db:       $db"
        red "  query:    $sql"
        red "  expected: $expected"
        red "  observed: $got"
        return 1
    fi
    green "  ✓ $label = $got"
}

# Convenience wrappers naming the instance, for legible call sites.
assert_sql_a() { assert_sql_i "$A_DB" "$1" "$2" "A: $3"; }
assert_sql_b() { assert_sql_i "$B_DB" "$1" "$2" "B: $3"; }

# assert_log_grep_i LOG PATTERN LABEL — fail unless PATTERN (grep -E) is in
# LOG. Reuses lib.sh's assert_log_grep semantics; thin alias for readability.
assert_log_grep_i() { assert_log_grep "$1" "$2" "$3"; }

# assert_log_absent LOG PATTERN LABEL — fail IF PATTERN appears in LOG. The
# spec leans hard on absence assertions (e.g. no 'outbox/follow: target inbox
# unknown') to prove a workaround actually fired.
assert_log_absent() {
    local log="$1" pattern="$2" label="${3:-absence}"
    if grep -Eq -- "$pattern" "$log" 2>/dev/null; then
        red "log unexpectedly CONTAINS $label: /$pattern/  ($log)"
        yellow "matching lines:"; grep -En -- "$pattern" "$log" >&2 || true
        return 1
    fi
    green "  ✓ $label absent (as required): /$pattern/"
}

# via_caddy_url URL — dump headers for a full URL and assert Via: …Caddy.
# Proves we're proxied, not hitting a socket by accident (SPEC §4.2).
via_caddy_url() {
    local url="$1" label="${2:-$url}"
    local hdrs
    hdrs=$(curl --silent --show-error --output /dev/null --dump-header - \
                --max-time 10 "$url" || true)
    assert_via_caddy "$hdrs" "$label"
}

# ===========================================================================
#  STEP 1 — build / locate the binary; assert it is executable.
#  Mirrors run.sh / run-caddy.sh exactly (bug #1 + the broken dev-shell build).
# ===========================================================================
note "STEP 1 — locate binary"
if [ -n "${ANNEXWYRM_BINARY:-}" ]; then
    BINARY="$ANNEXWYRM_BINARY"
else
    note "building annexwyrm via nix build .#default"
    ( cd "$REPO" && nix build .#default --out-link "$REPO/result" )
    BINARY="$REPO/result/bin/annexwyrm"
fi
if [ ! -x "$BINARY" ]; then
    red "binary not found / not executable (bug #1): $BINARY"
    exit 1
fi
green "  ✓ binary is executable: $BINARY"

# ===========================================================================
#  STEP 2 — generate + `caddy validate` both Caddyfiles (SPEC §4.1).
#
#  Site block keyed on 127.0.0.1:$PORT directly (we hit it by IP:port and our
#  minted ids use that authority — no hostname indirection). The multi-line
#  request_body block discipline (bug #3) still applies; caddy validate guards
#  it. No /static block (this suite asserts no CSS).
# ===========================================================================
note "STEP 2 — generate + validate both Caddyfiles"

write_caddyfile() {
    local file="$1" admin="$2" port="$3" sock="$4" access_log="$5"
    cat > "$file" <<EOF
{
    admin 127.0.0.1:${admin}
}

# Explicit http:// so Caddy does NOT attempt ACME/TLS. Keyed on 127.0.0.1:PORT
# so our minted ids (authority 127.0.0.1:PORT) resolve here directly.
http://127.0.0.1:${port} {
    encode zstd gzip

    # Multi-line block form is mandatory. The one-line
    # \`request_body { max_size 4GB }\` is a Caddyfile parse error (bug #3).
    request_body {
        max_size 4GB
    }

    reverse_proxy unix/${sock} {
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-Proto {scheme}
        transport http {
            versions 1.1
            read_buffer 64KB
            write_buffer 64KB
        }
    }

    log {
        output file ${access_log}
        format json
    }
}
EOF
}

validate_caddyfile() {
    local file="$1" label="$2"
    if ! caddy validate --config "$file" --adapter caddyfile \
            > "$TMP/validate.${label}.log" 2>&1; then
        red "caddy validate FAILED ($label, bug #3 territory) — Caddyfile + stderr:"
        yellow "----- Caddyfile ($label) -----"; cat "$file" >&2
        yellow "----- caddy validate output -----"; cat "$TMP/validate.${label}.log" >&2
        exit 1
    fi
    green "  ✓ Caddyfile validates ($label)"
}

write_caddyfile "$A_CADDYFILE" "$A_ADMIN" "$A_PORT" "$A_SOCK" "$A_CADDY_ACCESS_LOG"
write_caddyfile "$B_CADDYFILE" "$B_ADMIN" "$B_PORT" "$B_SOCK" "$B_CADDY_ACCESS_LOG"
validate_caddyfile "$A_CADDYFILE" "A"
validate_caddyfile "$B_CADDYFILE" "B"

# ===========================================================================
#  STEP 3 — init both data dirs with their full env (SPEC §4.3 step 1).
#  Assert each DB's local actor id equals $A_ACTOR / $B_ACTOR (catches base-URL
#  drift, the bug-#4 family). ANNEXWYRM_DOMAIN=127.0.0.1 so get-domain() matches
#  the host in the minted ids.
# ===========================================================================
note "STEP 3 — init both data dirs"

init_instance() {
    local domain="$1" base="$2" user="$3" instance="$4" pass="$5" data="$6"
    ANNEXWYRM_DOMAIN="$domain" \
    ANNEXWYRM_BASE_URL="$base" \
    ANNEXWYRM_USERNAME="$user" \
    ANNEXWYRM_INSTANCE_NAME="$instance" \
    ANNEXWYRM_PASSWORD="$pass" \
    ANNEXWYRM_DATA="$data" \
        "$BINARY" init "$data"
}

init_instance "$A_DOMAIN" "$A_BASE" "$A_USER" "$A_INSTANCE" "$A_PASS" "$A_DATA"
init_instance "$B_DOMAIN" "$B_BASE" "$B_USER" "$B_INSTANCE" "$B_PASS" "$B_DATA"

[ -f "$A_DB" ] || { red "init did not create $A_DB"; exit 1; }
[ -f "$B_DB" ] || { red "init did not create $B_DB"; exit 1; }

assert_sql_a "SELECT count(*) FROM actor WHERE local=1;" "1" "exactly one local actor"
assert_sql_b "SELECT count(*) FROM actor WHERE local=1;" "1" "exactly one local actor"
assert_sql_a "SELECT id FROM actor WHERE local=1;" "$A_ACTOR" \
    "actor id == \$A_ACTOR (base-URL coherence)"
assert_sql_b "SELECT id FROM actor WHERE local=1;" "$B_ACTOR" \
    "actor id == \$B_ACTOR (base-URL coherence)"
assert_sql_a "SELECT inbox FROM actor WHERE local=1;" "$A_INBOX" "A inbox minted from base"
assert_sql_b "SELECT inbox FROM actor WHERE local=1;" "$B_INBOX" "B inbox minted from base"
assert_sql_a "SELECT count(*) FROM local_login;" "1" "A has a login row"
assert_sql_b "SELECT count(*) FROM local_login;" "1" "B has a login row"
# Default manually_approves=0 ⇒ B will auto-accept A's follow (SPEC §1 step 2).
assert_sql_b "SELECT manually_approves FROM actor WHERE local=1;" "0" \
    "B auto-accepts (manually_approves=0)"

# ===========================================================================
#  STEP 4 — start both daemons, then both Caddys; confirm all four live
#  (SPEC §4.3 steps 2-3).
# ===========================================================================
note "STEP 4 — start both daemons + both Caddys"

start_daemon() {
    # serve with the SAME identity env (minus ANNEXWYRM_PASSWORD).
    # ANNEXWYRM_SERVE_DRAIN=0 disables the serve loop's idle auto-drain so
    # delivery is driven SOLELY by this test's explicit `annexwyrm drain`
    # calls. Without it the daemon's own 5s idle tick races the explicit
    # drain (delivers the Follow/Create before we can observe the pending
    # row), making the queue→deliver→success narrative non-deterministic.
    local domain="$1" base="$2" user="$3" instance="$4" sock="$5" data="$6" log="$7"
    ANNEXWYRM_DOMAIN="$domain" \
    ANNEXWYRM_BASE_URL="$base" \
    ANNEXWYRM_USERNAME="$user" \
    ANNEXWYRM_INSTANCE_NAME="$instance" \
    ANNEXWYRM_SOCKET="$sock" \
    ANNEXWYRM_DATA="$data" \
    ANNEXWYRM_SERVE_DRAIN="0" \
        "$BINARY" serve > "$log" 2>&1 &
    echo $!
}

A_DAEMON_PID="$(start_daemon "$A_DOMAIN" "$A_BASE" "$A_USER" "$A_INSTANCE" "$A_SOCK" "$A_DATA" "$A_DAEMON_LOG")"
B_DAEMON_PID="$(start_daemon "$B_DOMAIN" "$B_BASE" "$B_USER" "$B_INSTANCE" "$B_SOCK" "$B_DATA" "$B_DAEMON_LOG")"

wait_daemon_http() {
    local sock="$1" name="$2"
    wait_for_socket "$sock" 10 || { red "$name daemon failed to bring up its socket"; exit 1; }
    local ready=0 _
    for _ in $(seq 1 10); do
        if curl --silent --output /dev/null --max-time 2 \
                --unix-socket "$sock" "http://x/" >/dev/null 2>&1; then
            ready=1; break
        fi
        sleep 0.5
    done
    [ "$ready" = "1" ] || { red "$name daemon socket not accepting HTTP after 5s"; exit 1; }
    green "  ✓ $name daemon up + speaking HTTP on socket"
}
wait_daemon_http "$A_SOCK" "A"
wait_daemon_http "$B_SOCK" "B"

start_caddy() {
    local cfg="$1" log="$2"
    caddy run --config "$cfg" --adapter caddyfile > "$log" 2>&1 &
    echo $!
}
A_CADDY_PID="$(start_caddy "$A_CADDYFILE" "$A_CADDY_RUN_LOG")"
B_CADDY_PID="$(start_caddy "$B_CADDYFILE" "$B_CADDY_RUN_LOG")"

wait_caddy() {
    local pid="$1" base="$2" name="$3"
    local ok=0 _ code
    for _ in $(seq 1 20); do
        if ! kill -0 "$pid" 2>/dev/null; then
            red "$name Caddy process exited during startup"; exit 1
        fi
        code=$(curl --silent --output /dev/null --max-time 2 \
                --write-out '%{http_code}' "${base}/" 2>/dev/null || true)
        if [ -n "$code" ] && [ "$code" != "000" ]; then ok=1; break; fi
        sleep 0.5
    done
    [ "$ok" = "1" ] || { red "$name Caddy did not start accepting requests within ~10s"; exit 1; }
    green "  ✓ $name Caddy up (base $base)"
}
wait_caddy "$A_CADDY_PID" "$A_BASE" "A"
wait_caddy "$B_CADDY_PID" "$B_BASE" "B"

# All four PIDs alive; no crash markers in either daemon log.
kill -0 "$A_DAEMON_PID" 2>/dev/null || { red "A daemon died after launch"; exit 1; }
kill -0 "$B_DAEMON_PID" 2>/dev/null || { red "B daemon died after launch"; exit 1; }
kill -0 "$A_CADDY_PID"  2>/dev/null || { red "A Caddy died after launch"; exit 1; }
kill -0 "$B_CADDY_PID"  2>/dev/null || { red "B Caddy died after launch"; exit 1; }
for log in "$A_DAEMON_LOG" "$B_DAEMON_LOG"; do
    if grep -Eqi 'panic|internal error|EACCES' "$log"; then
        red "daemon log contains a crash marker: $log"; cat "$log" >&2; exit 1
    fi
done
green "  ✓ all four processes live (A daemon $A_DAEMON_PID, B daemon $B_DAEMON_PID, A caddy $A_CADDY_PID, B caddy $B_CADDY_PID)"

# ===========================================================================
#  STEP 4.5 — cross-reachability smoke (SPEC §4.3, MUST). Before any
#  federation, prove each instance can fetch the OTHER's actor as JSON-LD —
#  this is exactly what the signature-verification path will do over libcurl
#  (FINDING 3). Assert Via: 1.1 Caddy on both, proving the actor doc is served
#  through the peer's proxy along the same path libcurl will traverse.
# ===========================================================================
note "STEP 4.5 — cross-reachability smoke (each fetches the other's actor)"

# A fetches B's actor JSON-LD.
B_ACTOR_JSON="$(a_curl -H 'Accept: application/activity+json' "$B_ACTOR")"
assert_status_url "$B_ACTOR" 200 "A can GET B's actor"
echo "$B_ACTOR_JSON" | jq -e \
    --arg id "$B_ACTOR" '.id == $id and (.publicKey.publicKeyPem | contains("BEGIN PUBLIC KEY"))' \
    >/dev/null || {
        red "B's actor JSON-LD missing id==$B_ACTOR or a PEM public key"
        echo "$B_ACTOR_JSON" | head -40 >&2; exit 1; }
green "  ✓ B's actor JSON-LD has id=$B_ACTOR and a public key"
via_caddy_url "$B_ACTOR" "B actor doc via B's Caddy"

# B fetches A's actor JSON-LD (symmetric).
A_ACTOR_JSON="$(b_curl -H 'Accept: application/activity+json' "$A_ACTOR")"
assert_status_url "$A_ACTOR" 200 "B can GET A's actor"
echo "$A_ACTOR_JSON" | jq -e \
    --arg id "$A_ACTOR" '.id == $id and (.publicKey.publicKeyPem | contains("BEGIN PUBLIC KEY"))' \
    >/dev/null || {
        red "A's actor JSON-LD missing id==$A_ACTOR or a PEM public key"
        echo "$A_ACTOR_JSON" | head -40 >&2; exit 1; }
green "  ✓ A's actor JSON-LD has id=$A_ACTOR and a public key"
via_caddy_url "$A_ACTOR" "A actor doc via A's Caddy"

# ===========================================================================
#  TIER SELECTION (SPEC §0, §5 Prerequisite, FINDING 10).
#
#  Probe whether the binary supports the `drain` subcommand: run it once on
#  B's empty queue. The real subcommand reads ANNEXWYRM_DATA (not a CLI arg)
#  and prints a BARE integer count (here `0`, nothing pending). If it exits 0
#  and prints a count, Tier 1 is available. FED_FORCE_TIER0=1 forces Tier 0.
#
#  jq-style access-log reader: read the status of the LAST matching request
#  for a given URI in a Caddy json access log.
# ===========================================================================
note "TIER SELECTION — probing for the 'drain' subcommand"

# Run drain once for instance I (env-driven; bare-int count on stdout).
# Usage: run_drain <DATA> <DOMAIN> <BASE> <USER> <INSTANCE> <outlog>
run_drain() {
    local data="$1" domain="$2" base="$3" user="$4" instance="$5" outlog="$6"
    ANNEXWYRM_DOMAIN="$domain" \
    ANNEXWYRM_BASE_URL="$base" \
    ANNEXWYRM_USERNAME="$user" \
    ANNEXWYRM_INSTANCE_NAME="$instance" \
    ANNEXWYRM_DATA="$data" \
        "$BINARY" drain > "$outlog" 2>&1
}

TIER="0"
if [ "${FED_FORCE_TIER0:-0}" = "1" ]; then
    note "FED_FORCE_TIER0=1 → forcing Tier 0 regardless of 'drain' support"
else
    PROBE_LOG="$TMP/B/drain.probe.log"
    if run_drain "$B_DATA" "$B_DOMAIN" "$B_BASE" "$B_USER" "$B_INSTANCE" "$PROBE_LOG"; then
        # The drain prints a bare count; on an empty queue that is "0".
        PROBE_COUNT="$(grep -Eo '^[0-9]+$' "$PROBE_LOG" | tail -1 || true)"
        if [ -n "$PROBE_COUNT" ]; then
            TIER="1"
        else
            note "drain ran but printed no count (output below) → Tier 0"
            cat "$PROBE_LOG" >&2 || true
        fi
    else
        note "drain subcommand absent / non-zero exit → Tier 0 (no daemon-side delivery POST)"
    fi
fi

if [ "$TIER" = "1" ]; then
    green "================================================================"
    green "  SELECTED TIER 1 — the daemon's own 'drain' POSTs signed"
    green "  deliveries over HTTP A<->B. This is the real S2S wire test."
    green "================================================================"
else
    yellow "================================================================"
    yellow "  SELECTED TIER 0 — fallback. curl replays the exact signed"
    yellow "  bytes a drain would send, driving only the RECEIVER's inbound"
    yellow "  pipeline. The daemon's own delivery POST is NOT exercised."
    yellow "================================================================"
fi

# ===========================================================================
#  Caddy access-log helper: status of the LAST request matching a URI+method.
#  Used to read the inbox-POST status in Tier 1 (where the status is observed
#  on the wire, not via a curl write-out) and the actor-fetch proof in F1.
#
#  Caddy's JSON file logger flushes asynchronously, so a single read can race
#  the request that just completed. last_access_status polls (bounded, ~3s, no
#  foreground busy-sleep beyond 0.1s ticks) until a matching line appears, then
#  returns its status. Empty if none appears within the window.
# ===========================================================================
last_access_status() {
    local access_log="$1" uri="$2" method="$3"
    local i status
    for i in $(seq 1 30); do
        # The json access log records one object per line. Match the URI path
        # and method exactly; return the last status seen.
        status=$(jq -rs --arg uri "$uri" --arg m "$method" '
            map(select(.request.uri == $uri and .request.method == $m))
            | last | .status // empty' "$access_log" 2>/dev/null || true)
        if [ -n "$status" ]; then printf '%s' "$status"; return 0; fi
        sleep 0.1
    done
    printf '%s' "$status"
}
# Count requests matching URI+method (for "exactly one POST landed" proofs).
count_access() {
    local access_log="$1" uri="$2" method="$3"
    jq -rs --arg uri "$uri" --arg m "$method" '
        [ .[] | select(.request.uri == $uri and .request.method == $m) ] | length' \
        "$access_log" 2>/dev/null || echo 0
}

# ===========================================================================
#  TIER 0 signed-POST replay (SPEC §5, F2/F3/F5). Reproduces the EXACT bytes
#  the daemon's drain would send (src/ap/deliver_worker.kk deliver-one →
#  src/ap/sign.kk sign-outbound), so it exercises the RECEIVER's real inbound
#  pipeline (parse → fetch sender's actor → verify sig → dispatch → persist).
#
#  ********** THIS IS A STAND-IN FOR THE DAEMON'S OWN DELIVERY POST. **********
#  It is used ONLY in Tier 0; in Tier 1 the daemon signs its own bytes and we
#  never call this. It must replicate sign-outbound precisely:
#    - signed headers, in order: (request-target) host date digest
#    - digest = "SHA-256=" + base64(sha256(body))   (src/effects/crypto.kk
#      http-digest; openssl: sha256 -binary | base64 -A)
#    - host   = the inbox URL's authority (127.0.0.1:$PORT)  (core/url authority)
#    - (request-target) = "post " + inbox path              (lowercased method)
#    - canonical string = lines "name: value" joined with LF, NO trailing LF
#    - signature = base64( RSA-SHA256 sign of canonical string )
#    - Signature header field order matches build-signature-header:
#        keyId, algorithm="rsa-sha256", headers, signature
#  A digest/host/target mismatch surfaces as 401 at the inbox — which the test
#  would (correctly) fail on. FINDING 8 is exactly why Tier 1 is preferred.
# ===========================================================================

# tier0_signed_post <inbox_url> <body> <priv_key_pem_file> <key_id> <out_status_var>
# Echoes the HTTP status on stdout.
tier0_signed_post() {
    local inbox_url="$1" body="$2" privfile="$3" key_id="$4"
    # Parse the inbox URL: authority (host:port) + request path.
    local hostport path
    hostport="$(printf '%s' "$inbox_url" | sed -E 's#^https?://([^/]+).*#\1#')"
    path="$(printf '%s' "$inbox_url" | sed -E 's#^https?://[^/]+##')"

    # Digest: "SHA-256=" + base64(sha256(body)). MUST match http-digest exactly.
    local digest
    digest="SHA-256=$(printf '%s' "$body" | openssl dgst -sha256 -binary | openssl base64 -A)"

    # RFC 7231 date (GMT). LC_ALL=C to keep day/month names ASCII.
    local date
    date="$(LC_ALL=C TZ=GMT date '+%a, %d %b %Y %H:%M:%S GMT')"

    # Canonical signing string. Lines joined with LF, NO trailing newline.
    # Order: (request-target) host date digest  (sign-headers-post).
    local signing
    signing="$(printf '(request-target): post %s\nhost: %s\ndate: %s\ndigest: %s' \
        "$path" "$hostport" "$date" "$digest")"

    # RSA-SHA256 signature over the signing string, base64'd.
    local sig
    sig="$(printf '%s' "$signing" \
        | openssl dgst -sha256 -sign "$privfile" -binary | openssl base64 -A)"

    local sighdr
    sighdr="keyId=\"${key_id}\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date digest\",signature=\"${sig}\""

    curl --silent --show-error --output /dev/null \
        --write-out '%{http_code}' \
        -X POST \
        -H "Date: $date" \
        -H "Digest: $digest" \
        -H "Signature: $sighdr" \
        -H "Content-Type: application/activity+json" \
        -H "Accept: application/activity+json" \
        --data-binary "$body" \
        "$inbox_url"
}

# Extract instance I's private key PEM into a file (for Tier 0 signing).
extract_priv_key() {
    local db="$1" actor="$2" out="$3"
    sqlite3 "$db" "SELECT private_key_pem FROM actor WHERE id='$actor';" > "$out"
    [ -s "$out" ] || { red "could not extract private key for $actor from $db"; exit 1; }
}

# Deliver a single queued activity from sender→inbox. In Tier 1 we run the
# daemon's drain; in Tier 0 we replay the signed POST. Asserts the inbox
# returned 202 and that the drain (Tier 1) reported a count of `expected_n`.
#   deliver_and_expect <tier1_drain: A|B> <body> <inbox_url> <privfile> <key_id>
#       <access_log> <inbox_path> <expected_n> <drain_outlog> <label>
deliver_and_expect_202() {
    local who="$1" body="$2" inbox_url="$3" privfile="$4" key_id="$5"
    local access_log="$6" inbox_path="$7" expected_n="$8" drain_outlog="$9" label="${10}"

    if [ "$TIER" = "1" ]; then
        note "$label: Tier 1 drain on $who"
        case "$who" in
            A) run_drain "$A_DATA" "$A_DOMAIN" "$A_BASE" "$A_USER" "$A_INSTANCE" "$drain_outlog" ;;
            B) run_drain "$B_DATA" "$B_DOMAIN" "$B_BASE" "$B_USER" "$B_INSTANCE" "$drain_outlog" ;;
        esac
        # The drain must have reported it processed expected_n rows (bare int)
        # and exited 0 with no panic. (SPEC F2/F3/F5 (b).)
        if grep -Eqi 'panic|internal error' "$drain_outlog"; then
            red "$label: drain output contains a crash marker"; cat "$drain_outlog" >&2; exit 1
        fi
        local drained
        drained="$(grep -Eo '^[0-9]+$' "$drain_outlog" | tail -1 || true)"
        if [ "$drained" != "$expected_n" ]; then
            red "$label: drain reported count '$drained', expected '$expected_n'"
            yellow "drain output:"; cat "$drain_outlog" >&2
            exit 1
        fi
        green "  ✓ $label: drain processed $drained delivery row(s)"
        # Status is observed on the wire (peer's Caddy access log).
        local code
        code="$(last_access_status "$access_log" "$inbox_path" "POST")"
        if [ "$code" != "202" ]; then
            red "$label: inbox POST status (from access log) expected 202, got '$code'"
            yellow "access log tail:"; tail -5 "$access_log" >&2 || true
            exit 1
        fi
        green "  ✓ $label: peer's inbox returned 202 (from access log)"
    else
        note "$label: Tier 0 signed-POST replay (daemon-POST stand-in)"
        local code
        code="$(tier0_signed_post "$inbox_url" "$body" "$privfile" "$key_id")"
        if [ "$code" != "202" ]; then
            red "$label: inbox POST status expected 202, got '$code' (401 = sig verify failed)"
            exit 1
        fi
        green "  ✓ $label: inbox returned 202 (Tier 0 curl)"
    fi
}

# ===========================================================================
#  STEP F1 — A logs in, then A follows B (SPEC §5 F1).
#
#  We follow via the HTTP POST /follow endpoint, NEVER the CLI (FINDING 1):
#  only the handler's resolve-actor pre-fetch populates B's actor row so that
#  ship-follow's lookup-actor-inbox succeeds and a delivery is queued.
# ===========================================================================
note "STEP F1 — A logs in, then A follows B"

# (a) A logs in.
A_LOGIN_HDR="$TMP/A/login.headers"
: > "$A_JAR"
a_curl --output /dev/null --dump-header "$A_LOGIN_HDR" \
    --cookie-jar "$A_JAR" \
    --data-urlencode "username=$A_USER" \
    --data-urlencode "password=$A_PASS" \
    "$A_BASE/login"
a_login_status="$(head -1 "$A_LOGIN_HDR" | awk '{print $2}' | tr -d '\r')"
[ "$a_login_status" = "303" ] || { red "A login expected 303, got $a_login_status"; cat "$A_LOGIN_HDR" >&2; exit 1; }
green "  ✓ A login status 303"
A_LOGIN_HEADERS="$(cat "$A_LOGIN_HDR")"
a_login_loc="$(header_value "$A_LOGIN_HEADERS" "location")"
[ "$a_login_loc" = "/" ] || { red "A login Location expected '/', got '$a_login_loc'"; exit 1; }
A_SET_COOKIE="$(printf '%s\n' "$A_LOGIN_HEADERS" | grep -i '^set-cookie:' | head -1 | tr -d '\r')"
printf '%s' "$A_SET_COOKIE" | grep -Eq 'session=[^;[:space:]]+' \
    || { red "A login set no session cookie"; exit 1; }
if printf '%s' "$A_SET_COOKIE" | grep -qi 'secure'; then
    red "A Set-Cookie carries 'Secure' over http:// (bug #6): $A_SET_COOKIE"; exit 1; fi
assert_via_caddy "$A_LOGIN_HEADERS" "A login"
green "  ✓ A logged in (session cookie, no Secure)"

# (a) A follows B via POST /follow (form target=$B_ACTOR, absolute URL — not
#     the acct: form; FINDING 6).
A_FOLLOW_HDR="$TMP/A/follow.headers"
a_curl --output /dev/null --dump-header "$A_FOLLOW_HDR" \
    --cookie "$A_JAR" \
    --data-urlencode "target=$B_ACTOR" \
    "$A_BASE/follow"
a_follow_status="$(head -1 "$A_FOLLOW_HDR" | awk '{print $2}' | tr -d '\r')"
[ "$a_follow_status" = "303" ] || { red "A follow expected 303, got $a_follow_status"; cat "$A_FOLLOW_HDR" >&2; exit 1; }
A_FOLLOW_HEADERS="$(cat "$A_FOLLOW_HDR")"
a_follow_loc="$(header_value "$A_FOLLOW_HEADERS" "location")"
[ "$a_follow_loc" = "/" ] || { red "A follow Location expected '/', got '$a_follow_loc'"; exit 1; }
assert_via_caddy "$A_FOLLOW_HEADERS" "A follow"
green "  ✓ A POST /follow → 303 Location /"

# (b) daemon logs — A MUST NOT have logged the 'target inbox unknown' warning;
#     its absence proves FINDING 1's handler pre-fetch fired (B's actor cached,
#     so ship-follow's lookup-actor-inbox succeeded and queued a delivery).
assert_log_absent "$A_DAEMON_LOG" 'outbox/follow: target inbox unknown' \
    "F1 A: no 'outbox/follow: target inbox unknown' (FINDING 1 workaround fired)"
# (b) B MUST have served its actor doc to A's fetch (over-the-wire proof via
#     B's Caddy access log: GET /users/belgarath → 200). The §4.5 smoke fetch
#     (A curling B's actor as a raw HTTP client) does NOT populate A's daemon
#     cache — only the daemon's own fetch-actor does — so the follow handler's
#     resolve-actor triggers a SECOND, fresh GET here. We therefore assert B
#     served at least TWO such GETs (smoke + the follow-triggered daemon fetch),
#     and that its last status was 200. The definitive proof is the SQL row
#     below (B cached as a remote actor on A); this is the wire corroboration.
b_actor_status="$(last_access_status "$B_CADDY_ACCESS_LOG" "/users/$B_USER" "GET")"
[ "$b_actor_status" = "200" ] || {
    red "F1: expected B's Caddy last GET /users/$B_USER → 200 (A's actor fetch), got '$b_actor_status'"
    tail -10 "$B_CADDY_ACCESS_LOG" >&2 || true; exit 1; }
b_actor_gets="$(count_access "$B_CADDY_ACCESS_LOG" "/users/$B_USER" "GET")"
[ "$b_actor_gets" -ge 2 ] 2>/dev/null || {
    red "F1: expected ≥2 GET /users/$B_USER on B's Caddy (smoke + follow-triggered daemon fetch), got '$b_actor_gets'"
    tail -10 "$B_CADDY_ACCESS_LOG" >&2 || true; exit 1; }
green "  ✓ F1 B: served $b_actor_gets GET /users/$B_USER (last 200) — daemon fetched B's actor over the wire"

# (c) SQL — A_DB: B cached as a remote actor + a pending follow + queued delivery.
assert_sql_a "SELECT count(*) FROM actor WHERE id='$B_ACTOR' AND local=0;" "1" \
    "F1: B cached as remote actor on A (FINDING 1 proof)"
assert_sql_a "SELECT inbox FROM actor WHERE id='$B_ACTOR';" "$B_INBOX" \
    "F1: B's cached inbox == \$B_INBOX"
assert_sql_a "SELECT length(public_key_pem) > 0 FROM actor WHERE id='$B_ACTOR';" "1" \
    "F1: B's cached public key non-empty"
assert_sql_a "SELECT count(*) FROM follow WHERE follower_id='$A_ACTOR' AND target_id='$B_ACTOR' AND state='pending';" "1" \
    "F1: A has a pending follow of B"
assert_sql_a "SELECT type FROM activity WHERE actor_id='$A_ACTOR' AND type='Follow';" "Follow" \
    "F1: A emitted a Follow activity"
assert_sql_a "SELECT object_id FROM activity WHERE type='Follow' AND actor_id='$A_ACTOR';" "$B_ACTOR" \
    "F1: Follow object_id == \$B_ACTOR"

FOLLOW_AID="$(sqlite3 "$A_DB" "SELECT id FROM activity WHERE type='Follow' AND actor_id='$A_ACTOR';")"
[ -n "$FOLLOW_AID" ] || { red "F1: could not capture FOLLOW_AID"; exit 1; }
note "FOLLOW_AID = $FOLLOW_AID"
assert_sql_a "SELECT count(*) FROM delivery WHERE inbox_url='$B_SHARED_INBOX' AND state='pending';" "1" \
    "F1: one delivery queued to B's SHARED inbox, pending"
assert_sql_a "SELECT activity_id FROM delivery WHERE inbox_url='$B_SHARED_INBOX';" "$FOLLOW_AID" \
    "F1: queued delivery activity_id == FOLLOW_AID"
assert_sql_a "SELECT sender_id FROM delivery WHERE inbox_url='$B_SHARED_INBOX';" "$A_ACTOR" \
    "F1: queued delivery sender_id == \$A_ACTOR"
assert_sql_a "SELECT attempts FROM delivery WHERE inbox_url='$B_SHARED_INBOX';" "0" \
    "F1: queued delivery attempts == 0"

# (c) SQL — B_DB: nothing yet (the Follow is only queued on A).
assert_sql_b "SELECT count(*) FROM follow;" "0" "F1: B has no follow rows yet"
assert_sql_b "SELECT count(*) FROM activity WHERE inbox_remote=1;" "0" \
    "F1: B has no inbound activities yet"

# ===========================================================================
#  STEP F2 — deliver A's Follow to B; B auto-accepts (SPEC §5 F2).
# ===========================================================================
note "STEP F2 — deliver A's Follow to B (B auto-accepts)"

FOLLOW_BODY="$(sqlite3 "$A_DB" "SELECT raw FROM activity WHERE id='$FOLLOW_AID';")"
[ -n "$FOLLOW_BODY" ] || { red "F2: empty Follow body"; exit 1; }
A_KEY="$TMP/A/A.key"
[ "$TIER" = "1" ] || extract_priv_key "$A_DB" "$A_ACTOR" "$A_KEY"

# (a)/(b): deliver and assert 202 + (Tier 1) drain count 1, no panic.
# Delivery targets B's SHARED inbox ($B_SHARED_INBOX → POST /inbox), where
# handle-shared-inbox verifies the signature. The HTTP-signature host is the URL
# authority (127.0.0.1:$B_PORT), unchanged by personal-vs-shared, so signing
# still matches; only the path/target move from /users/<u>/inbox to /inbox.
deliver_and_expect_202 "A" "$FOLLOW_BODY" "$B_SHARED_INBOX" "$A_KEY" "$A_ACTOR#main-key" \
    "$B_CADDY_ACCESS_LOG" "/inbox" "1" "$TMP/A/drain.f2.log" \
    "F2 deliver Follow A→B"

# (b) B daemon logs: dispatch Follow; absence of the failure markers.
assert_log_grep_i "$B_DAEMON_LOG" \
    "^\[info\] inbox/dispatch id=http://127\.0\.0\.1:$A_PORT/activities/[0-9a-f]+ type=Follow\$" \
    "F2 B: inbox/dispatch …type=Follow"
assert_log_absent "$B_DAEMON_LOG" 'inbox/unsigned' "F2 B: no inbox/unsigned (signature verified)"
assert_log_absent "$B_DAEMON_LOG" 'inbox/follow: queued for manual approval' \
    "F2 B: no manual-approval (auto-accept default)"
assert_log_absent "$B_DAEMON_LOG" 'inbox/follow: target is not us' \
    "F2 B: no 'target is not us' (Follow object is B)"
assert_log_absent "$B_DAEMON_LOG" 'inbox/follow: follower actor not cached' \
    "F2 B: no 'follower actor not cached' (FINDING 3 fetch satisfied lookup)"

# (c) SQL — B_DB reflects received + auto-accepted follow.
assert_sql_b "SELECT count(*) FROM actor WHERE id='$A_ACTOR' AND local=0;" "1" \
    "F2: B fetched + cached A for verification (FINDING 3)"
assert_sql_b "SELECT inbox FROM actor WHERE id='$A_ACTOR';" "$A_INBOX" \
    "F2: A's cached inbox on B == \$A_INBOX"
assert_sql_b "SELECT state FROM follow WHERE follower_id='$A_ACTOR' AND target_id='$B_ACTOR';" "accepted" \
    "F2: B auto-accepted A's follow"
assert_sql_b "SELECT id FROM follow WHERE follower_id='$A_ACTOR';" "$FOLLOW_AID" \
    "F2: follow row id == FOLLOW_AID (A's Follow activity id)"
assert_sql_b "SELECT accepted_at IS NOT NULL FROM follow WHERE id='$FOLLOW_AID';" "1" \
    "F2: follow accepted_at set"
assert_sql_b "SELECT count(*) FROM activity WHERE id='$FOLLOW_AID' AND inbox_remote=1;" "1" \
    "F2: inbound Follow persisted (inbox_remote=1)"

# B minted an Accept back to A, queued for delivery.
ACCEPT_AID="$(sqlite3 "$B_DB" "SELECT id FROM activity WHERE type='Accept' AND actor_id='$B_ACTOR';")"
[ -n "$ACCEPT_AID" ] || { red "F2: could not capture ACCEPT_AID"; exit 1; }
note "ACCEPT_AID = $ACCEPT_AID"
assert_sql_b "SELECT count(*) FROM delivery WHERE inbox_url='$A_SHARED_INBOX' AND state='pending';" "1" \
    "F2: one Accept delivery queued to A's SHARED inbox, pending"
assert_sql_b "SELECT raw LIKE '%$FOLLOW_AID%' FROM activity WHERE id='$ACCEPT_AID';" "1" \
    "F2: Accept references the Follow id"
assert_sql_b "SELECT sender_id FROM delivery WHERE inbox_url='$A_SHARED_INBOX';" "$B_ACTOR" \
    "F2: Accept delivery sender_id == \$B_ACTOR"
assert_sql_b "SELECT attempts FROM delivery WHERE inbox_url='$A_SHARED_INBOX';" "0" \
    "F2: Accept delivery attempts == 0"

# (c) SQL — A_DB: the Follow delivery transitioned by tier.
if [ "$TIER" = "1" ]; then
    assert_sql_a "SELECT state FROM delivery WHERE activity_id='$FOLLOW_AID';" "success" \
        "F2: A's Follow delivery → success (Tier 1 drain POSTed it)"
else
    assert_sql_a "SELECT state FROM delivery WHERE activity_id='$FOLLOW_AID';" "pending" \
        "F2: A's Follow delivery still pending (Tier 0 never sent it)"
    note "Tier 0: the daemon never POSTed A's Follow; only the receiver pipeline ran."
fi
# A's follow row stays pending until F3.
assert_sql_a "SELECT state FROM follow WHERE id='$FOLLOW_AID';" "pending" \
    "F2: A's follow still pending (Accept not yet received)"

# ===========================================================================
#  STEP F3 — deliver B's Accept back to A (SPEC §5 F3).
# ===========================================================================
note "STEP F3 — deliver B's Accept back to A"

ACCEPT_BODY="$(sqlite3 "$B_DB" "SELECT raw FROM activity WHERE id='$ACCEPT_AID';")"
[ -n "$ACCEPT_BODY" ] || { red "F3: empty Accept body"; exit 1; }
B_KEY="$TMP/B/B.key"
[ "$TIER" = "1" ] || extract_priv_key "$B_DB" "$B_ACTOR" "$B_KEY"

deliver_and_expect_202 "B" "$ACCEPT_BODY" "$A_SHARED_INBOX" "$B_KEY" "$B_ACTOR#main-key" \
    "$A_CADDY_ACCESS_LOG" "/inbox" "1" "$TMP/B/drain.f3.log" \
    "F3 deliver Accept B→A"

# (b) A daemon logs: dispatch Accept; no inbox/unsigned.
assert_log_grep_i "$A_DAEMON_LOG" \
    "^\[info\] inbox/dispatch id=http://127\.0\.0\.1:$B_PORT/activities/[0-9a-f]+ type=Accept\$" \
    "F3 A: inbox/dispatch …type=Accept"
assert_log_absent "$A_DAEMON_LOG" 'inbox/unsigned' "F3 A: no inbox/unsigned"

# (c) SQL — A_DB: pending follow promoted to accepted; Accept persisted inbound.
assert_sql_a "SELECT state FROM follow WHERE id='$FOLLOW_AID';" "accepted" \
    "F3: A's follow promoted to accepted"
assert_sql_a "SELECT accepted_at IS NOT NULL FROM follow WHERE id='$FOLLOW_AID';" "1" \
    "F3: A's follow accepted_at set"
assert_sql_a "SELECT count(*) FROM activity WHERE id='$ACCEPT_AID' AND inbox_remote=1;" "1" \
    "F3: inbound Accept persisted on A (inbox_remote=1)"

# (c) SQL — B_DB: Accept delivery success (Tier 1) / pending (Tier 0).
if [ "$TIER" = "1" ]; then
    assert_sql_b "SELECT state FROM delivery WHERE activity_id='$ACCEPT_AID';" "success" \
        "F3: B's Accept delivery → success (Tier 1)"
else
    assert_sql_b "SELECT state FROM delivery WHERE activity_id='$ACCEPT_AID';" "pending" \
        "F3: B's Accept delivery still pending (Tier 0)"
fi

# Checkpoint: A is an accepted follower of B as seen from BOTH sides.
assert_sql_a "SELECT state FROM follow WHERE follower_id='$A_ACTOR' AND target_id='$B_ACTOR';" "accepted" \
    "F3 checkpoint: A_DB sees follow accepted"
assert_sql_b "SELECT state FROM follow WHERE follower_id='$A_ACTOR' AND target_id='$B_ACTOR';" "accepted" \
    "F3 checkpoint: B_DB sees follow accepted"

# ===========================================================================
#  STEP F4 — B publishes a public item (SPEC §5 F4).
#  Uploading does not federate; publishing does (FINDING 4).
# ===========================================================================
note "STEP F4 — B uploads then publishes a public item"

# (a) B logs in.
B_LOGIN_HDR="$TMP/B/login.headers"
: > "$B_JAR"
b_curl --output /dev/null --dump-header "$B_LOGIN_HDR" \
    --cookie-jar "$B_JAR" \
    --data-urlencode "username=$B_USER" \
    --data-urlencode "password=$B_PASS" \
    "$B_BASE/login"
b_login_status="$(head -1 "$B_LOGIN_HDR" | awk '{print $2}' | tr -d '\r')"
[ "$b_login_status" = "303" ] || { red "B login expected 303, got $b_login_status"; cat "$B_LOGIN_HDR" >&2; exit 1; }
assert_via_caddy "$(cat "$B_LOGIN_HDR")" "B login"
green "  ✓ B login status 303"

# (a) B uploads a public PDF (reuse upload_tcp's field discipline: -F file
#     with explicit ;type=, --form-string for literals). We post a full URL,
#     so we inline the multipart curl rather than upload_tcp (which is keyed
#     on the single CADDY_BASE global).
PDF_FED="$TMP/B/federated.pdf"
python3 "$THIS_DIR/make-pdf.py" "Federated Treatise: across the wire" > "$PDF_FED"
[ -s "$PDF_FED" ] || { red "empty federated PDF"; exit 1; }

B_UP_HDR="$TMP/B/upload.headers"
B_UP_BODY="$TMP/B/upload.body"
b_curl --cookie "$B_JAR" \
    --dump-header "$B_UP_HDR" --output "$B_UP_BODY" \
    -F "file=@$PDF_FED;type=application/pdf" \
    --form-string "name=Federated Treatise" \
    --form-string "summary=" \
    --form-string "content=<p>Across the wire.</p>" \
    --form-string "privacy=public" \
    --form-string "rating=99" \
    --form-string "in_reply_to=" \
    "$B_BASE/upload"
B_UP_HEADERS="$(cat "$B_UP_HDR")"
ITEM_PATH="$(header_value "$B_UP_HEADERS" "location")"
printf '%s' "$ITEM_PATH" | grep -Eq '^/items/[0-9a-f]+$' \
    || { red "F4: upload Location not /items/<hex>: '$ITEM_PATH'"; cat "$B_UP_HDR" >&2; exit 1; }
assert_via_caddy "$B_UP_HEADERS" "B upload"
ITEM_URL="$B_BASE$ITEM_PATH"
note "ITEM_PATH = $ITEM_PATH   ITEM_URL = $ITEM_URL"

# (b) B upload log line.
assert_log_grep_i "$B_DAEMON_LOG" \
    "^\[info\] upload/done id=$ITEM_URL size=[0-9]+ remotes=0" \
    "F4 B: upload/done id=\$ITEM_URL"

# (a) B publishes the item — this fires emit-create.
B_PUB_HDR="$TMP/B/publish.headers"
b_curl --cookie "$B_JAR" --output /dev/null --dump-header "$B_PUB_HDR" \
    -X POST --data '' "$B_BASE$ITEM_PATH/publish"
b_pub_status="$(head -1 "$B_PUB_HDR" | awk '{print $2}' | tr -d '\r')"
[ "$b_pub_status" = "303" ] || { red "F4: publish expected 303, got $b_pub_status"; cat "$B_PUB_HDR" >&2; exit 1; }
B_PUB_HEADERS="$(cat "$B_PUB_HDR")"
b_pub_loc="$(header_value "$B_PUB_HEADERS" "location")"
[ "$b_pub_loc" = "$ITEM_PATH" ] || { red "F4: publish Location expected '$ITEM_PATH', got '$b_pub_loc'"; exit 1; }
assert_via_caddy "$B_PUB_HEADERS" "B publish"
green "  ✓ B publish → 303 Location $ITEM_PATH"

# (b) THE HEADLINE: outbox/publish recipients=1 — the Create fanned out to
#     exactly one inbox (A's), because A is B's only accepted follower. A
#     regression to recipients=0 fails here loudly (the whole handshake
#     mattered). SPEC §8 sabotage 2.
assert_log_grep_i "$B_DAEMON_LOG" \
    "^\[info\] outbox/publish id=http://127\.0\.0\.1:$B_PORT/activities/[0-9a-f]+ type=Create recipients=1\$" \
    "F4 B: outbox/publish …type=Create recipients=1 (HEADLINE)"

# (c) SQL — B_DB.
assert_sql_b "SELECT privacy FROM item WHERE id='$ITEM_URL';" "public" "F4: item is public"
assert_sql_b "SELECT count(*) FROM activity WHERE type='Create' AND object_id='$ITEM_URL' AND inbox_remote=0;" "1" \
    "F4: exactly one outbound Create for the item"
CREATE_AID="$(sqlite3 "$B_DB" "SELECT id FROM activity WHERE type='Create' AND object_id='$ITEM_URL' AND inbox_remote=0;")"
[ -n "$CREATE_AID" ] || { red "F4: could not capture CREATE_AID"; exit 1; }
note "CREATE_AID = $CREATE_AID"
assert_sql_b "SELECT actor_id FROM activity WHERE id='$CREATE_AID';" "$B_ACTOR" \
    "F4: Create actor_id == \$B_ACTOR"
assert_sql_b "SELECT raw LIKE '%\"type\":\"Create\"%' AND raw LIKE '%$ITEM_URL%' FROM activity WHERE id='$CREATE_AID';" "1" \
    "F4: Create raw embeds the item URL"
assert_sql_b "SELECT count(*) FROM delivery WHERE activity_id='$CREATE_AID' AND inbox_url='$A_SHARED_INBOX' AND state='pending';" "1" \
    "F4: one Create delivery queued to A's SHARED inbox, pending"
assert_sql_b "SELECT count(*) FROM delivery WHERE activity_id='$CREATE_AID';" "1" \
    "F4: exactly one delivery row for the Create"
assert_sql_b "SELECT sender_id FROM delivery WHERE activity_id='$CREATE_AID';" "$B_ACTOR" \
    "F4: Create delivery sender_id == \$B_ACTOR"
assert_sql_b "SELECT attempts FROM delivery WHERE activity_id='$CREATE_AID';" "0" \
    "F4: Create delivery attempts == 0"
assert_sql_b "SELECT last_error IS NULL FROM delivery WHERE activity_id='$CREATE_AID';" "1" \
    "F4: Create delivery last_error is NULL"

# (c) SQL — A_DB: nothing delivered yet.
assert_sql_a "SELECT count(*) FROM activity WHERE object_id='$ITEM_URL';" "0" \
    "F4: A has not yet received the Create"

# ===========================================================================
#  STEP F5 — the drain delivers the signed Create to A; A persists it
#  (SPEC §5 F5). The climax: a daemon-driven (Tier 1) signed POST from B's
#  outbox to A's real inbox.
# ===========================================================================
note "STEP F5 — deliver the Create B→A; A persists the remote activity"

CREATE_BODY="$(sqlite3 "$B_DB" "SELECT raw FROM activity WHERE id='$CREATE_AID';")"
[ -n "$CREATE_BODY" ] || { red "F5: empty Create body"; exit 1; }

deliver_and_expect_202 "B" "$CREATE_BODY" "$A_SHARED_INBOX" "$B_KEY" "$B_ACTOR#main-key" \
    "$A_CADDY_ACCESS_LOG" "/inbox" "1" "$TMP/B/drain.f5.log" \
    "F5 deliver Create B→A"

# (b) A daemon logs: dispatch Create; no inbox/unsigned, no inbox/duplicate.
assert_log_grep_i "$A_DAEMON_LOG" \
    "^\[info\] inbox/dispatch id=http://127\.0\.0\.1:$B_PORT/activities/[0-9a-f]+ type=Create\$" \
    "F5 A: inbox/dispatch …type=Create"
assert_log_absent "$A_DAEMON_LOG" "inbox/duplicate id=$CREATE_AID" \
    "F5 A: no inbox/duplicate yet (first delivery)"

# (c) SQL — A_DB: A holds the remote activity AND the remote object reference.
assert_sql_a "SELECT count(*) FROM activity WHERE id='$CREATE_AID' AND inbox_remote=1;" "1" \
    "F5: remote Create landed on A (inbox_remote=1)"
assert_sql_a "SELECT actor_id FROM activity WHERE id='$CREATE_AID';" "$B_ACTOR" \
    "F5: Create actor_id == \$B_ACTOR"
assert_sql_a "SELECT object_id FROM activity WHERE id='$CREATE_AID';" "$ITEM_URL" \
    "F5: Create object_id == \$ITEM_URL"
assert_sql_a "SELECT raw LIKE '%$ITEM_URL%' AND raw LIKE '%Federated Treatise%' FROM activity WHERE id='$CREATE_AID';" "1" \
    "F5: full published object body stored in A's activity.raw"
# FINDING 9: A stores the activity, NOT a remote item row. Asserting an item
# row would test behavior the code deliberately does not have.
assert_sql_a "SELECT count(*) FROM item WHERE id='$ITEM_URL';" "0" \
    "F5: A creates NO item row for B's object (FINDING 9)"

# (c) SQL — B_DB: delivery pending→success, retry/backoff untouched (FINDING 7).
if [ "$TIER" = "1" ]; then
    assert_sql_b "SELECT state FROM delivery WHERE activity_id='$CREATE_AID';" "success" \
        "F5: B's Create delivery → success (Tier 1 daemon POST)"
else
    assert_sql_b "SELECT state FROM delivery WHERE activity_id='$CREATE_AID';" "pending" \
        "F5: B's Create delivery still pending (Tier 0 did not transition it)"
    note "Tier 0: receiver end-state on A is identical to Tier 1; only the sender row differs."
fi
# Retry/backoff NOT exercised — explicit (FINDING 7).
assert_sql_b "SELECT attempts FROM delivery WHERE activity_id='$CREATE_AID';" "0" \
    "F5: Create delivery attempts == 0 (retry/backoff NOT exercised)"
assert_sql_b "SELECT last_error IS NULL FROM delivery WHERE activity_id='$CREATE_AID';" "1" \
    "F5: Create delivery last_error is NULL"
assert_sql_b "SELECT count(*) FROM delivery WHERE state='failed';" "0" \
    "F5: no failed deliveries on B (nothing gave up)"

# ===========================================================================
#  STEP F6 — negative controls (prove the assertions have teeth; SPEC §5 F6).
#  These use curl in BOTH tiers (the queue is drained, so a re-drain finds
#  nothing; we POST the same bytes directly).
# ===========================================================================
note "STEP F6 — negative controls (dedup + unsigned)"

# For Tier 1 we never extracted B's key (the daemon signed its own bytes), so
# extract it now for the curl-driven negative controls.
[ -s "$B_KEY" ] 2>/dev/null || extract_priv_key "$B_DB" "$B_ACTOR" "$B_KEY"

# --- Idempotency / dedup: re-POST the exact signed Create to A's inbox. A MUST
#     return 202 again but log inbox/duplicate, and store no duplicate row.
note "F6.1 — dedup: re-deliver the Create to A"
dup_code="$(tier0_signed_post "$A_SHARED_INBOX" "$CREATE_BODY" "$B_KEY" "$B_ACTOR#main-key")"
[ "$dup_code" = "202" ] || { red "F6 dedup: expected 202 on re-POST, got '$dup_code'"; exit 1; }
green "  ✓ F6 dedup: re-POST returned 202"
assert_log_grep_i "$A_DAEMON_LOG" "^\[info\] inbox/duplicate id=$CREATE_AID\$" \
    "F6 A: inbox/duplicate id=\$CREATE_AID"
assert_sql_a "SELECT count(*) FROM activity WHERE id='$CREATE_AID';" "1" \
    "F6 dedup: still exactly one Create row on A (no duplicate)"

# --- Unsigned rejection: POST the Create body with NO Signature header. A MUST
#     return 401 and log inbox/unsigned; the activity count is unchanged.
note "F6.2 — unsigned: POST the Create body to A with no Signature"
unsigned_code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    -X POST \
    -H "Content-Type: application/activity+json" \
    --data-binary "$CREATE_BODY" \
    "$A_SHARED_INBOX" || true)"
[ "$unsigned_code" = "401" ] || { red "F6 unsigned: expected 401, got '$unsigned_code'"; exit 1; }
green "  ✓ F6 unsigned: returned 401"
assert_log_grep_i "$A_DAEMON_LOG" "^\[warn\] inbox/unsigned from=$B_ACTOR type=Create" \
    "F6 A: inbox/unsigned from=\$B_ACTOR type=Create"
assert_sql_a "SELECT count(*) FROM activity WHERE id='$CREATE_AID';" "1" \
    "F6 unsigned: Create row count unchanged on A (still 1)"

# ===========================================================================
#  Done.
# ===========================================================================
green ""
green "=========================================="
green "  federation e2e passed (Tier $TIER)."
green "  A: $A_BASE  socket $A_SOCK"
green "  B: $B_BASE  socket $B_SOCK"
green "  data: $A_DATA  +  $B_DATA"
if [ "$TIER" = "0" ]; then
    yellow "  NOTE: ran Tier 0 — the daemon's own delivery POST was NOT"
    yellow "  exercised (drain subcommand absent / FED_FORCE_TIER0). Receiver"
    yellow "  end-state is identical, but the wire POST was curl, not the daemon."
fi
green "=========================================="
