// annexwyrm/ap/addressing — `to` / `cc` / `bto` / `bcc` / `audience`
// resolution and visibility predicates.
//
// Pure: takes a list of URLs (whatever the activity addressed) and
// classifies it. The actual fanning out to inboxes is done by
// `ap/outbox` against the database.

module ap/addressing

import core/types

// True iff any of the supplied addresses is the Public collection in
// any of its three accepted forms.
pub fun addresses-public( addresses : list<string> ) : bool
  addresses.any(is-public-iri)

// True iff any address points at the followers collection for `actor-id`.
// We compare against the conventional URL pattern; remote followers
// collections may use other patterns and we can't know them all.
pub fun addresses-followers( actor-id : url, addresses : list<string> ) : bool
  val expected = actor-id ++ "/followers"
  addresses.any(fn(a) a == expected)

// Determine the visibility tier of an activity from its `to` and `cc`.
// This is for incoming activities; we use it to filter the inbox view.
pub fun infer-visibility( actor-id : url, to : list<string>, cc : list<string> ) : privacy
  val all = to ++ cc
  if addresses-public(to) then ItPublic
  elif addresses-public(cc) then ItUnlisted
  elif addresses-followers(actor-id, all) then ItFollowers
  else ItPrivate

// Build outbound `to`/`cc` lists from a privacy choice and the actor's
// followers collection. Mentions (extra `to` recipients) are appended
// to the result of the privacy-driven defaults.
pub fun build-addressing( privacy : privacy, followers : url, mentions : list<url> )
                        : (list<url>,list<url>)
  match privacy
    ItPublic    -> ([ap-public-iri] ++ mentions, [followers])
    ItFollowers -> ([followers] ++ mentions, [])
    ItUnlisted  -> (mentions, [ap-public-iri, followers])
    ItPrivate   -> (mentions, [])
