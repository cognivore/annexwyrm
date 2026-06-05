// annexwyrm/interp/store_rclone — Store → rclone subprocess.
//
// The handler is built on top of the `shell` effect; we don't shell out
// directly. The remote handle is interpreted as an rclone "remote:" name
// (e.g. "rsyncnet"). The blob key is its path inside.

module interp/store_rclone

import effects/store
import effects/shell

pub fun with-rclone-store( action : () -> <store,shell|e> a ) : <shell|e> a
  with handler
    fun blob-put(loc : blob-loc, bytes : string)
      val _ = run(["rclone", "rcat", loc.show], bytes)
      ()
    fun blob-get(loc : blob-loc)
      val r = run(["rclone", "cat", loc.show], "")
      if r.ok then Just(r.stdout) else Nothing
    fun blob-del(loc : blob-loc)
      val _ = run(["rclone", "deletefile", loc.show], "")
      ()
    fun blob-has(loc : blob-loc)
      val r = run(["rclone", "lsf", loc.show], "")
      r.ok && r.stdout != ""
    fun blob-size(loc : blob-loc)
      val r = run(["rclone", "size", "--json", loc.show], "")
      if !r.ok then Nothing
      else extract-size(r.stdout)
    fun blob-public-url(loc : blob-loc)
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
