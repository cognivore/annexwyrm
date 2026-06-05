// annexwyrm/interp/log_console — Log → stderr.

module interp/log_console

import effects/log

extern import
  c file "../../csrc/log_bridge.c"

// One line, straight to stderr, flushed. The previous `println` here went
// to stdout, which is fully buffered when redirected to a file (launchd's
// StandardOutPath, the e2e harness's `> daemon.log 2>&1`), so a running
// daemon's log lines sat invisible in the stdio buffer until exit —
// production daemon.log was empty and the Caddy e2e's log assertions
// failed. See csrc/log_bridge.c.
extern kk-aw-log-line( line : string ) : console ()
  c "kk_aw_log_line"

// Install a handler that writes one line per log call to stderr.
// Output format: `[LEVEL] msg key1=val1 key2=val2 …`.
pub fun with-console-log( action : () -> <log,console|e> a ) : <console|e> a
  with handler
    fun emit(lvl : log-level, msg : string, fields : list<(string,string)>)
      val tags = fields.map(fn(p) p.fst ++ "=" ++ p.snd).join(" ")
      val line = "[" ++ lvl.show ++ "] " ++ msg ++
                 (if tags == "" then "" else " " ++ tags)
      kk-aw-log-line(line)
  action()
