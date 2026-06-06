// annexwyrm/interp/shell_proc — Shell → process via C bridge.
//
// `kk-spawn(argv, stdin)` returns `"<exit>\x1f<stderr>\x1f<stdout>"`.
//
// STDOUT is the FINAL field because it is binary: blob-get (`rclone cat`)
// of an archived PDF/JPEG/audio yields bytes containing 0x1F, so stdout
// must survive a split-limit decode verbatim. (A mid-record stdout used
// to truncate at the first 0x1F and silently corrupt publish-later
// copies.) The C side strips 0x1F from exit/stderr.

module interp/shell_proc

import effects/shell
import interp/str

extern import
  c file "../../csrc/proc_bridge.c"

extern kk-spawn( argv : string, stdin : string ) : <ndet,fsys> string
  c "kk_aw_spawn"

fun encode-argv( xs : list<string> ) : string
  xs.join("\x1f")

fun parse-result( s : string ) : shell-result
  match s.split-limit("\x1f", 2)
    Just((Cons(code, Cons(err, Nil)), out)) ->
      Shell-result(code.parse-int.default(127), out, err)
    _ -> Shell-result(127, "", "spawn failed")

pub fun with-process-shell( action : () -> <shell,ndet,fsys|e> a ) : <ndet,fsys|e> a
  with handler
    fun run(argv : list<string>, stdin : string)
      parse-result(kk-spawn(encode-argv(argv), stdin))
  action()
