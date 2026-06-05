// annexwyrm/effects/log — structured logging.
//
// Algorithms emit log records through this effect; the production
// interpreter (interp/log_console) writes them to stderr in
// logfmt-ish form, while tests can install a buffer.

module effects/log

pub type log-level
  LogDebug
  LogInfo
  LogWarn
  LogError

pub fun log-level/show( l : log-level ) : string
  match l
    LogDebug -> "debug"
    LogInfo  -> "info"
    LogWarn  -> "warn"
    LogError -> "error"

// A single log entry. Fields are emitted as `k=v` pairs after `msg`.
// Algorithms produce one of these per call; the handler is responsible
// for formatting and routing.
pub effect log
  fun emit( level : log-level, msg : string, fields : list<(string,string)> ) : ()

// Convenience helpers.
pub fun debug( msg : string, fields : list<(string,string)> = [] ) : log ()
  emit(LogDebug, msg, fields)

pub fun info( msg : string, fields : list<(string,string)> = [] ) : log ()
  emit(LogInfo, msg, fields)

pub fun warn( msg : string, fields : list<(string,string)> = [] ) : log ()
  emit(LogWarn, msg, fields)

pub fun error( msg : string, fields : list<(string,string)> = [] ) : log ()
  emit(LogError, msg, fields)
