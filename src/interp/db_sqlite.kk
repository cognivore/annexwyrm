// annexwyrm/interp/db_sqlite — Db → SQLite via C bridge.
//
// Each `query` and `exec` is one prepared statement, fully bound from
// the params list, executed and the rows shipped back as a list of
// lists of `sql-value`. The C bridge owns the `sqlite3 *` handle; we
// pass an opaque pointer through as an int.

module interp/db_sqlite

import effects/db

extern import
  c file "../../csrc/db_bridge.c"

// Open / close the connection. The fd-like int is the SQLite handle.
pub extern kk-db-open( path : string ) : <ndet,fsys> int
  c "kk_aw_db_open"

pub extern kk-db-close( h : int ) : <ndet,fsys> ()
  c "kk_aw_db_close"

// Execute a statement (INSERT/UPDATE/DELETE/DDL). Params are serialised
// as one big string: `T\tval\nT\tval\n…` where T is 't' for text, 'i'
// for int, 'n' for null. The C side parses this back.
extern kk-db-exec( h : int, sql : string, params : string ) : <ndet,fsys> int
  c "kk_aw_db_exec"

// Execute a SELECT. Returns rows as one big string in the same delimiter
// form; the Koka side parses it into `sql-value`s.
extern kk-db-query( h : int, sql : string, params : string ) : <ndet,fsys> string
  c "kk_aw_db_query"

extern kk-db-last-rowid( h : int ) : <ndet,fsys> int
  c "kk_aw_db_last_rowid"

// Run a multi-statement SQL script. Returns 0 on success.
pub extern kk-db-exec-script( h : int, sql : string ) : <ndet,fsys> int
  c "kk_aw_db_exec_script"

// Apply the schema baked into the binary. Returns 0 on success.
pub extern kk-db-init-schema( h : int ) : <ndet,fsys> int
  c "kk_aw_db_init_schema"

// ----------------------------------------------------------------------
//  The handler
// ----------------------------------------------------------------------

pub fun with-sqlite-db( db-h : int, action : () -> <db,ndet,fsys|e> a ) : <ndet,fsys|e> a
  with handler
    fun query(sql : string, params : list<sql-value>)
      parse-rows(kk-db-query(db-h, sql, encode-params(params)))
    fun exec(sql : string, params : list<sql-value>)
      kk-db-exec(db-h, sql, encode-params(params))
    fun last-insert-rowid()
      kk-db-last-rowid(db-h)
  action()

// ----------------------------------------------------------------------
//  Param marshalling
// ----------------------------------------------------------------------

// `t\tvalue\x1e` per param.  `\x1e` (record separator) terminates each
// param; `\t` separates the type tag from the value.
fun encode-params( ps : list<sql-value> ) : string
  ps.map(encode-one).join("")

fun encode-one( v : sql-value ) : string
  match v
    SqlNull    -> "n\t\x1e"
    SqlText(s) -> "t\t" ++ s ++ "\x1e"
    SqlInt(n)  -> "i\t" ++ n.show ++ "\x1e"

// Result rows come back as: row1col1\x1frow1col2\x1f…\x1erow2col1\x1f…
// where \x1f is unit separator (within row) and \x1e is record separator
// (between rows). Cells are tagged like params.
fun parse-rows( s : string ) : list<sql-row>
  if s == "" then []
  else s.split("\x1e").filter(fn(r) r != "").map(parse-row)

fun parse-row( s : string ) : sql-row
  s.split("\x1f").map(parse-cell)

fun parse-cell( s : string ) : sql-value
  match s.split("\t")
    Cons("n", _) -> SqlNull
    Cons("t", Cons(v, _)) -> SqlText(v)
    Cons("i", Cons(v, _)) -> SqlInt(v.parse-int.default(0))
    _ -> SqlNull
