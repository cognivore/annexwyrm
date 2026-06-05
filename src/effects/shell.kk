// annexwyrm/effects/shell — subprocess escape hatch.
//
// Algorithms never call this directly. It exists so the `store` and
// `crypto` interpreters can spawn `rclone`, `git-annex`, `openssl`
// without each privately inventing a subprocess primitive.

module effects/shell

pub value struct shell-result
  exit-code : int
  stdout    : string
  stderr    : string

pub fun shell-result/ok( r : shell-result ) : bool
  r.exit-code == 0

pub effect shell
  // Spawn `argv[0]` with the remaining as arguments, pipe `stdin` to
  // it, capture stdout and stderr. Returns when the child exits.
  // The interpreter does NOT shell-interpret `argv`; tokens are passed
  // verbatim to `execvp(3)`.
  fun run( argv : list<string>, stdin : string ) : shell-result
