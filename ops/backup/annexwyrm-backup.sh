#!/usr/bin/env bash
# annexwyrm-backup — nightly, self-verifying backup of the annexwyrm database.
#
# The files annexwyrm archives are already off-box (encrypted on the tenant's
# cloud). The SQLite database — every review, rating, tag, follower, and the
# map from item to blob — lived only on this box. This job snapshots it with
# sqlite's online backup (consistent even mid-write, WAL included), gzips it,
# copies it into the ENCRYPTED archive remote under annexwyrm-db/, reads that
# copy back through the crypt layer, runs PRAGMA integrity_check on it, then
# prunes copies older than KEEP_DAYS. Any failure exits non-zero, so the
# systemd unit shows failed and `journalctl -u annexwyrm-backup` says why.
#
# Installed once per box (see README.md here); runs from
# /opt/annexwyrm/ops/backup via annexwyrm-backup.timer, as root, with root's
# own rclone config (the daemon uses the tenant's copy, so neither touches
# the other's token).
set -euo pipefail

DATA="${ANNEXWYRM_DATA:-/var/lib/annexwyrm}"
RCLONE_CONF="${ANNEXWYRM_BACKUP_RCLONE_CONF:-/root/.config/rclone/rclone.conf}"
REMOTE="${ANNEXWYRM_BACKUP_REMOTE:-gdrive-crypt:annexwyrm-db}"
KEEP_DAYS="${ANNEXWYRM_BACKUP_KEEP_DAYS:-60}"

stamp=$(date -u +%Y%m%d-%H%M%SZ)
name="annexwyrm-$stamp.db.gz"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sqlite3 "$DATA/annexwyrm.db" ".backup '$tmp/snapshot.db'"
rows=$(sqlite3 "$tmp/snapshot.db" \
  "select (select count(*) from item) || ' items, ' || (select count(*) from actor) || ' actors'")
gzip -9 -c "$tmp/snapshot.db" > "$tmp/$name"
size=$(stat -c %s "$tmp/$name")

rclone --config "$RCLONE_CONF" copyto "$tmp/$name" "$REMOTE/$name"

# Read the uploaded copy back and prove it is a sound database before trusting it.
rclone --config "$RCLONE_CONF" cat "$REMOTE/$name" > "$tmp/readback.db.gz"
[ "$(stat -c %s "$tmp/readback.db.gz")" = "$size" ] \
  || { echo "readback of $REMOTE/$name is $(stat -c %s "$tmp/readback.db.gz") bytes, upload was $size" >&2; exit 1; }
gzip -dc "$tmp/readback.db.gz" > "$tmp/readback.db"
check=$(sqlite3 "$tmp/readback.db" "PRAGMA integrity_check;")
[ "$check" = "ok" ] || { echo "integrity_check on the uploaded copy: $check" >&2; exit 1; }

rclone --config "$RCLONE_CONF" delete --min-age "${KEEP_DAYS}d" "$REMOTE"
kept=$(rclone --config "$RCLONE_CONF" lsf "$REMOTE" | wc -l)
echo "backed up $rows -> $REMOTE/$name ($size bytes), verified by readback + integrity_check; $kept copies kept (<= $KEEP_DAYS days)"
