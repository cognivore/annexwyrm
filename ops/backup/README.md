# Nightly database backup

`annexwyrm-backup.sh` snapshots `/var/lib/annexwyrm/annexwyrm.db` (sqlite online
backup), gzips it, copies it to `gdrive-crypt:annexwyrm-db/annexwyrm-<UTC stamp>.db.gz`,
reads that copy back through the crypt layer, runs `PRAGMA integrity_check`, and
prunes copies older than 60 days. The blobs themselves already live on the same
encrypted remote under `annexwyrm/`; the crypt password + salt are in rageveil
(`rclone/gdrive-crypt`), so the database and the files are recoverable without
this box.

## Install (once per box, as root; deploy.sh keeps the script current)

    cp /opt/annexwyrm/ops/backup/annexwyrm-backup.{service,timer} /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now annexwyrm-backup.timer
    systemctl start annexwyrm-backup.service     # run one now
    journalctl -u annexwyrm-backup -o cat         # "backed up N items ... verified"

## Restore

    systemctl stop annexwyrm
    rclone lsf gdrive-crypt:annexwyrm-db/                       # pick a copy
    rclone cat gdrive-crypt:annexwyrm-db/annexwyrm-<stamp>.db.gz | gzip -dc > /var/lib/annexwyrm/annexwyrm.db
    rm -f /var/lib/annexwyrm/annexwyrm.db-wal /var/lib/annexwyrm/annexwyrm.db-shm
    systemctl start annexwyrm

On a fresh box, first recreate `/root/.config/rclone/rclone.conf`: a `gdrive`
remote authorised against the Workspace account, and `gdrive-crypt` over
`gdrive:annexwyrm-archive` with the password and salt from rageveil.
