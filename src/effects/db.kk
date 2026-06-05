// annexwyrm/effects/db — persistent state.
//
// We model SQL with three primitive operations: `query` (read), `exec`
// (write), and a scoped `with-tx` for transactions. Parameter binding
// uses a small sum so we don't pretend NULL is the empty string.
//
// The production interpreter (interp/db_sqlite) talks to SQLite; tests
// can install an in-memory dictionary.

module effects/db

// A SQL value.  Blobs are base64-encoded as `SqlText` to avoid carrying
// raw bytes through the boundary; there are no blob columns in our
// schema anyway.
pub type sql-value
  SqlNull
  SqlText( s : string )
  SqlInt( n : int )

pub alias sql-row = list<sql-value>

pub fun sql-value/show( v : sql-value ) : string
  match v
    SqlNull    -> "NULL"
    SqlText(s) -> "'" ++ s ++ "'"
    SqlInt(n)  -> n.show

pub effect db
  // Run a SELECT (or any read-only statement). Returns rows in declared
  // column order.
  fun query( sql : string, params : list<sql-value> ) : list<sql-row>

  // Run an INSERT / UPDATE / DELETE / DDL. Returns rows-affected.
  fun exec( sql : string, params : list<sql-value> ) : int

  // Return the last `INTEGER PRIMARY KEY AUTOINCREMENT` value inserted
  // on this connection, or 0 if none.
  fun last-insert-rowid() : int

// Helpers ------------------------------------------------------------

// Get the single text value out of a one-row, one-column result. Returns
// Nothing on empty result or non-text.
pub fun first-text( rows : list<sql-row> ) : maybe<string>
  match rows
    Cons(Cons(SqlText(s), _), _) -> Just(s)
    _ -> Nothing

// Get the single integer value out of a one-row, one-column result.
pub fun first-int( rows : list<sql-row> ) : maybe<int>
  match rows
    Cons(Cons(SqlInt(n), _), _) -> Just(n)
    _ -> Nothing

// Look up a column in a row by its index. Returns SqlNull on out-of-range.
pub fun col( row : sql-row, i : int ) : sql-value
  row.col-go(i)

fun col-go( row : sql-row, i : int ) : sql-value
  match row
    Nil          -> SqlNull
    Cons(v, _) | i == 0 -> v
    Cons(_, rs)  -> rs.col-go(i - 1)

// Convenience for parameter lists.
pub fun txt( s : string ) : sql-value
  SqlText(s)

pub fun num( n : int ) : sql-value
  SqlInt(n)

pub fun nul() : sql-value
  SqlNull
