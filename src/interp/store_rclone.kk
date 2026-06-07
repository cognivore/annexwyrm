// annexwyrm/interp/store_rclone — Store → rclone subprocess.
//
// The handler is built on top of the `shell` effect; we don't shell out
// directly. The remote handle is interpreted as an rclone "remote:" name
// (e.g. "rsyncnet"). The blob key is its path inside.

module interp/store_rclone

import effects/store
import effects/shell
import effects/config

pub fun with-rclone-store( action : () -> <store,shell,config|e> a ) : <shell,config|e> a
  with handler
    fun blob-put(loc : blob-loc, bytes : string)
      val _ = run(["rclone", "rcat", loc.show], bytes)
      ()
    fun blob-get(loc : blob-loc)
      val r = run(["rclone", "cat", loc.show], "")
      if r.ok then Just(r.stdout) else Nothing
    fun blob-del(loc : blob-loc)
      // --drive-use-trash=false: on Google Drive, PERMANENTLY delete the
      // object instead of moving it to Trash. This is what revokes a public
      // download when a file is un-published: a trashed Drive file is
      // recoverable for ~30 days and a previously-minted share link can still
      // resolve it, so trashing would leave the "private" file reachable. For
      // non-Drive backends (local, S3, …) rclone accepts the flag as a no-op.
      val _ = run(["rclone", "deletefile", "--drive-use-trash=false", loc.show], "")
      ()
    fun blob-has(loc : blob-loc)
      val r = run(["rclone", "lsf", loc.show], "")
      r.ok && r.stdout != ""
    fun blob-size(loc : blob-loc)
      val r = run(["rclone", "size", "--json", loc.show], "")
      if !r.ok then Nothing
      else extract-size(r.stdout)
    fun blob-public-url(loc : blob-loc)
      // The hermetic test seam (and any S3-style remote behind a CDN): when
      // ANNEXWYRM_PUBLIC_URL_BASE is set, construct a deterministic URL from
      // the blob key instead of asking rclone. `rclone link` returns Nothing
      // for a local-backend path, so the temp-dir e2e suites cannot mint a
      // URL there; this base makes the publish PIPELINE assertable offline.
      val base = get-public-url-base()
      if base != "" then Just(base ++ "/" ++ loc.key)
      else
        val r = run(["rclone", "link", loc.show], "")
        if !r.ok then Nothing
        else
          val u = r.stdout.trim
          if u == "" then Nothing else Just(u)
  action()

// Extract the numeric "bytes": <n> from rclone's size --json output.
fun extract-size( out : string ) : maybe<int>
  match out.find("\"bytes\":")
    Nothing -> Nothing
    Just(slc) ->
      val rest = slc.after.string.trim
      val digits = rest.list.take-while(fn(c) c.is-digit)
      digits.string.parse-int
