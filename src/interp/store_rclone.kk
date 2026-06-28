// annexwyrm/interp/store_rclone — Store → rclone subprocess.
//
// The handler is built on top of the `shell` effect; we don't shell out
// directly. The remote handle is interpreted as an rclone "remote:" name
// (e.g. "rsyncnet"). The blob key is its path inside.
//
// Multitenant: each blob-loc carries the OWNING tenant's materialised
// rclone.conf path (`loc.conf`), passed as `rclone --config <path>`, so a
// tenant's operations run against that tenant's own cloud backend. There is no
// ambient/host fallback for anyone (a blank config is rejected upstream in
// load-tenant-store); an empty `loc.conf` here is only the defensive no-op.
// `materialize-conf` writes a tenant's config to a private, content-addressed
// file via the fs bridge — written once, then owned by rclone (its token
// refreshes persist; see materialize-conf).

module interp/store_rclone

import effects/store
import effects/shell
import effects/config

extern import
  c file "../../csrc/fs_bridge.c"

// Write `bytes` to `path` as a private (0600) file, atomically. Returns 0 on
// success, <0 on failure. Secrets reach the filesystem only — never argv/env.
extern kk-write-private-file( path : string, bytes : string ) : <ndet,fsys> int
  c "kk_aw_write_private_file"

// 1 if `path` exists, else 0. For write-if-absent on the materialised config.
extern kk-file-exists( path : string ) : <ndet,fsys> int
  c "kk_aw_file_exists"

// rclone argv with the tenant's config injected. An empty `conf` runs rclone
// with no `--config` (ambient). `--config` must precede the subcommand.
fun rclone( conf : string, args : list<string> ) : list<string>
  if conf == "" then Cons("rclone", args)
  else Cons("rclone", Cons("--config", Cons(conf, args)))

pub fun with-rclone-store( action : () -> <store,shell,config,ndet,fsys|e> a )
  : <shell,config,ndet,fsys|e> a
  with handler
    fun blob-put(loc : blob-loc, bytes : string)
      val _ = run(rclone(loc.conf, ["rcat", loc.show]), bytes)
      ()
    fun blob-get(loc : blob-loc)
      val r = run(rclone(loc.conf, ["cat", loc.show]), "")
      if r.ok then Just(r.stdout) else Nothing
    fun blob-del(loc : blob-loc)
      // --drive-use-trash=false: on Google Drive, PERMANENTLY delete the
      // object instead of moving it to Trash. This is what revokes a public
      // download when a file is un-published: a trashed Drive file is
      // recoverable for ~30 days and a previously-minted share link can still
      // resolve it, so trashing would leave the "private" file reachable. For
      // non-Drive backends (local, S3, …) rclone accepts the flag as a no-op.
      val _ = run(rclone(loc.conf, ["deletefile", "--drive-use-trash=false", loc.show]), "")
      ()
    fun blob-has(loc : blob-loc)
      val r = run(rclone(loc.conf, ["lsf", loc.show]), "")
      r.ok && r.stdout != ""
    fun blob-size(loc : blob-loc)
      val r = run(rclone(loc.conf, ["size", "--json", loc.show]), "")
      if !r.ok then Nothing
      else extract-size(r.stdout)
    fun blob-public-url(loc : blob-loc)
      // The hermetic test seam (and any S3-style remote behind a CDN): when
      // the tenant's url-base is set, construct a deterministic URL from the
      // blob key instead of asking rclone. `rclone link` returns Nothing for
      // a local-backend path, so the temp-dir e2e suites cannot mint a URL
      // there; this base makes the publish PIPELINE assertable offline.
      if loc.url-base != "" then Just(loc.url-base ++ "/" ++ loc.key)
      else
        val r = run(rclone(loc.conf, ["link", loc.show]), "")
        if !r.ok then Nothing
        else
          val u = r.stdout.trim
          if u == "" then Nothing else Just(u)
    fun materialize-conf(owner : string, conf : string)
      if conf == "" then ""
      else
        // Name the file by a hash of the config CONTENT: a given config always
        // maps to the same path, so we write it ONCE (write-if-absent) and
        // thereafter rclone owns it. When rclone refreshes an OAuth token it
        // rewrites the config IN PLACE; because we never overwrite an existing
        // file from the original DB copy, that refresh PERSISTS (no per-op
        // re-refresh, no lost refresh-token rotation). A changed config hashes
        // to a NEW path → a fresh file, so edits still take effect.
        val path = get-data-dir() ++ "/storage/" ++
                   safe-name(owner) ++ "-" ++ hash-conf(conf).show ++ ".conf"
        // Best-effort write if absent; on failure the path is returned anyway
        // and the ensuing `rclone --config <missing>` fails loudly (→ 5xx),
        // never silently using the wrong/ambient backend.
        if kk-file-exists(path) == 0 then
          val _ = kk-write-private-file(path, conf)
          ()
        path
    fun storage-self-test(loc : blob-loc)
      // Real round-trip through THIS tenant's config: write a tiny probe, read
      // it back byte-exact, then delete it. "" = the secrets are set and the
      // backend genuinely accepts media; otherwise the first failing step's
      // rclone stderr (trimmed) — the same diagnostic the tenant would have
      // hit on their first real upload, surfaced up front instead.
      val probe = "annexwyrm-storage-self-test"
      val w = run(rclone(loc.conf, ["rcat", loc.show]), probe)
      if !w.ok then short-err("write failed", w.stderr)
      else
        val r = run(rclone(loc.conf, ["cat", loc.show]), "")
        // Always clean up the probe, regardless of the read outcome.
        val _ = run(rclone(loc.conf, ["deletefile", "--drive-use-trash=false", loc.show]), "")
        if !r.ok then short-err("read-back failed", r.stderr)
        elif r.stdout != probe then "read-back mismatch: the bytes did not round-trip intact"
        else ""
  action()

// Compress an rclone stderr blob to one short line for display: last
// non-empty line, capped, control bytes stripped. Falls back to `label`.
fun short-err( label : string, stderr : string ) : string
  val last = stderr.split("\n").map(fn(s) s.trim).filter(fn(s) s != "").reverse.head.default("")
  val clean = last.list.filter(fn(c) c >= ' ' && c != '\x7f').string
  val capped = if clean.count > 200 then clean.list.take(200).string ++ "…" else clean
  if capped == "" then label else label ++ ": " ++ capped

// A filesystem-safe per-tenant config filename derived from the actor id
// (a URL like "https://dom/users/alice"). Keep word chars, dot, dash; map
// everything else (slashes, ':') to '_'. Deterministic and collision-free
// among local actors (usernames are unique per instance domain), and with no
// '/' it can never escape <data-dir>/storage/.
fun safe-name( owner : string ) : string
  owner.list.map(fn(c)
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
       (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_'
      then c else '_'
  ).string

// A stable polynomial hash of the config CONTENT (mod a large prime < 2^63),
// used to name its materialised file so a given config always maps to one
// path. A collision would need two DIFFERENT configs for the SAME owner to
// coincide on ~63 bits — negligible.
fun hash-conf( s : string ) : int
  s.list.foldl(0, fn(h, c) (h * 1000003 + c.int) % 9223372036854775783)

// Extract the numeric "bytes": <n> from rclone's size --json output.
fun extract-size( out : string ) : maybe<int>
  match out.find("\"bytes\":")
    Nothing -> Nothing
    Just(slc) ->
      val rest = slc.after.string.trim
      val digits = rest.list.take-while(fn(c) c.is-digit)
      digits.string.parse-int
