// annexwyrm/web/prefs — persisted display preferences, backed by the
// `setting` table (key TEXT PRIMARY KEY, value TEXT). Kept separate from
// the handlers so any of them can read a preference without import cycles
// (handler/settings needs handler/item's session check; handler/item needs
// the width — this module is the neutral ground both import).

module web/prefs

import effects/db

// The container max-width — the "responsiveness mode". One of
// 860px / 1080px / 1440px / none (= unlimited). Stored as the literal CSS
// max-width value so layout can emit it verbatim. Default (and the value
// returned for a missing or corrupted row): 1080px.
pub fun get-page-width() : db string
  val rows = query("SELECT value FROM setting WHERE key = 'container_width'", [])
  match rows.first-text
    Just(v) -> if valid-width(v) then v else "1080px"
    Nothing -> "1080px"

// True iff `v` is one of the four allowed modes. The setter and the POST
// handler both validate against this, so no free-form CSS can ever be
// stored (the stored value is emitted inside a <style> block).
pub fun valid-width( v : string ) : bool
  v == "860px" || v == "1080px" || v == "1440px" || v == "none"

// Persist a (pre-validated) width. Caller validates with valid-width.
pub fun set-page-width( v : string ) : db ()
  val _ = exec(
    "INSERT OR REPLACE INTO setting (key, value) VALUES ('container_width', ?)",
    [txt(v)])
  ()
