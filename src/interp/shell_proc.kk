// annexwyrm/interp/shell_proc — Shell → process via C bridge.
//
// `kk-spawn(argv, stdin)` returns `"<exit>\x1f<stdout>\x1f<stderr>"`.

module interp/shell_proc

import effects/shell

extern import
  c file "../../csrc/proc_bridge.c"

extern kk-spawn( argv : string, stdin : string ) : <ndet,fsys> string
  c "kk_aw_spawn"

fun encode-argv( xs : list<string> ) : string
  xs.join("\x1f")

fun parse-result( s : string ) : shell-result
  match s.split("\x1f")
    Cons(code, Cons(out, Cons(err, _))) ->
      Shell-result(code.parse-int.default(127), out, err)
    Cons(code, Cons(out, _)) ->
      Shell-result(code.parse-int.default(127), out, "")
    _ -> Shell-result(127, "", "spawn failed")

pub fun with-process-shell( action : () -> <shell,ndet,fsys|e> a ) : <ndet,fsys|e> a
  with handler
    fun run(argv : list<string>, stdin : string)
      parse-result(kk-spawn(encode-argv(argv), stdin))
  action()
