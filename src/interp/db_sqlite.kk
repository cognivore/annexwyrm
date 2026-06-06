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
//
// A TEXT value can contain ANY byte — including the framing bytes
// themselves (a remote ActivityPub field with a raw 0x1E/0x1F, or a review
// body with a tab). Unescaped, such a byte truncates the value and shifts
// every subsequent bind, silently suppressing writes or binding to the
// wrong column. So text values are byte-stuffed (db-escape) here and on the
// way back out (db-unescape); the C bridge mirrors this. Int/null values are
// digits / empty and need no escaping. See the matching code in db_bridge.c
// and the \x1f-framing note in NOTES.md — same lesson, the DB param channel.
fun encode-params( ps : list<sql-value> ) : string
  ps.map(encode-one).join("")

fun encode-one( v : sql-value ) : string
  match v
    SqlNull    -> "n\t\x1e"
    SqlText(s) -> "t\t" ++ db-escape(s) ++ "\x1e"
    SqlInt(n)  -> "i\t" ++ n.show ++ "\x1e"

// Byte-stuff the framing-significant control bytes behind an 0x1D escape so
// a value can never contain a raw separator: 0x1D→\x1dD, 0x1E→\x1dE,
// 0x1F→\x1dF, TAB→\x1dT. (These are all single ASCII codepoints — never the
// continuation/lead bytes of a UTF-8 multibyte char — so mapping per
// codepoint is byte-exact.)
val esc-byte : char = 29.char   // the byte-stuffing escape (0x1D)

fun db-escape( s : string ) : string
  s.list.map(esc-ch).join("")

// NB: built via char concat, not a "\x1dD" literal — Koka's \x escape would
// greedily absorb the following hex letter (D/E/F) into the hex value.
fun esc-pair( tag : char ) : string
  esc-byte.string ++ tag.string

fun esc-ch( c : char ) : string
  if c == 29.char then esc-pair('D')
  elif c == 30.char then esc-pair('E')
  elif c == 31.char then esc-pair('F')
  elif c == '\t' then esc-pair('T')
  else c.string

fun db-unescape( s : string ) : string
  unesc-go(s.list, [])

fun unesc-go( cs : list<char>, acc : list<char> ) : string
  match cs
    Nil -> acc.reverse.string
    Cons(c, rest) ->
      if c == 29.char then
        match rest
          Cons(e, r2) -> unesc-go(r2, Cons(unmap-esc(e), acc))
          // Trailing lone escape byte: keep it literal and finish (no
          // recursion on [] — keeps this structurally total, which the db
          // effect's `query` op requires).
          Nil         -> (Cons(c, acc)).reverse.string
      else unesc-go(rest, Cons(c, acc))

fun unmap-esc( e : char ) : char
  if e == 'D' then 29.char
  elif e == 'E' then 30.char
  elif e == 'F' then 31.char
  elif e == 'T' then '\t'
  else e

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
    Cons("t", Cons(v, _)) -> SqlText(db-unescape(v))
    Cons("i", Cons(v, _)) -> SqlInt(v.parse-int.default(0))
    _ -> SqlNull
