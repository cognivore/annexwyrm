// annexwyrm/effects/config — read-only runtime configuration.
//
// Treated as an effect rather than a global record so tests can install
// alternate values without touching the file-system or environment.

module effects/config

pub effect config
  // The domain that appears in every `id` URL ("annexwyrm.example.com").
  fun get-domain() : string

  // The HTTPS origin ("https://annexwyrm.example.com"). Convenience built
  // from the domain by the production handler.
  fun get-base-url() : string

  // Absolute path to the data directory (database, blob staging, keys).
  fun get-data-dir() : string

  // Username of the single local actor. (We model a single-user instance;
  // multi-actor support is a schema-level change, not a re-design.)
  fun get-local-username() : string

  // True iff incoming Follows are queued for manual approval instead of
  // being auto-Accepted.
  fun get-manually-approves() : bool

  // The user-friendly name of the instance, e.g. "Alice's archive".
  fun get-instance-name() : string
