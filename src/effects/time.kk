// annexwyrm/effects/time — the wall clock.
//
// Three formats covered, since the AP / HTTP world mixes them:
//   * ISO 8601 UTC      "2026-06-04T12:34:56Z"   (AP `published`, `updated`)
//   * RFC 7231 HTTP-date "Thu, 04 Jun 2026 12:34:56 GMT"  (HTTP `Date`)
//   * Unix epoch seconds                                  (queue scheduling)

module effects/time

import core/types

pub effect time
  fun now-iso() : iso-time
  fun now-http() : string
  fun now-unix() : int
  fun iso-from-unix( unix : int ) : iso-time

// Add `seconds` to a Unix timestamp. Pure; no effect required. Useful
// for scheduling: `delivery.next-attempt = now-unix().add-seconds(60).iso`.
pub fun add-seconds( unix : int, secs : int ) : int
  unix + secs
