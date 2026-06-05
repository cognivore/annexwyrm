// annexwyrm/interp/log_console — Log → stderr.

module interp/log_console

import effects/log

// Install a handler that writes one line per log call to stderr.
// Output format: `[LEVEL] msg key1=val1 key2=val2 …`.
pub fun with-console-log( action : () -> <log,console|e> a ) : <console|e> a
  with handler
    fun emit(lvl : log-level, msg : string, fields : list<(string,string)>)
      val tags = fields.map(fn(p) p.fst ++ "=" ++ p.snd).join(" ")
      val line = "[" ++ lvl.show ++ "] " ++ msg ++
                 (if tags == "" then "" else " " ++ tags)
      println(line)
  action()
