// annexwyrm/core/types — the atoms used across every layer.
//
// Nothing in this module performs I/O. Construction is pure.

module core/types

// ----------------------------------------------------------------------
//  Identifiers
// ----------------------------------------------------------------------

// Stable identifier. For local objects this is the full HTTPS URL that
// also serves as the AP `id`. For remote rows it's the URL we fetched
// it from. For sessions / queue rows it's an opaque random token.
pub alias id = string

// A URL. Structured parsing lives in `core/url`; everywhere else we
// pass these around as strings.
pub alias url = string

// ISO 8601 UTC timestamp (e.g. "2026-06-04T12:34:56Z"). Sortable
// lexicographically; valid for AP `published`, `updated`, etc.
pub alias iso-time = string

// ----------------------------------------------------------------------
//  Media types
// ----------------------------------------------------------------------

// A parsed RFC 6838 media type. "application/pdf; charset=utf-8" becomes
// `Media-type("application","pdf",[("charset","utf-8")])`.
pub value struct media-type
  kind   : string
  sub    : string
  params : list<(string,string)>

pub fun media-type/show( m : media-type ) : string
  val base = m.kind ++ "/" ++ m.sub
  match m.params
    Nil -> base
    ps  -> base ++ "; " ++ ps.map(fn(p) p.fst ++ "=" ++ p.snd).join("; ")

// Parse a Content-Type-ish string. We split on '/' and ';'; we do not
// validate token grammar. Whitespace around params is trimmed.
pub fun media-type/parse( s : string ) : maybe<media-type>
  match s.split("/")
    Cons(k, Cons(rest, Nil)) ->
      match rest.split(";")
        Cons(sub, ps) ->
          val params = ps.map(fn(p) parse-param(p.trim))
          Just(Media-type(k.trim, sub.trim, params))
        Nil -> Nothing
    _ -> Nothing

fun parse-param( s : string ) : (string,string)
  match s.split("=")
    Cons(k, Cons(v, _)) -> (k.trim, v.trim.unquote)
    _                   -> (s.trim, "")

fun unquote( s : string ) : string
  if s.starts-with("\"").bool && s.ends-with("\"").bool && s.count >= 2
    then s.list.tail.init.string
    else s

// ----------------------------------------------------------------------
//  Actor and object kinds
// ----------------------------------------------------------------------

// AP Actor type discriminator. Group/Organization are not modelled.
pub type actor-kind
  AkPerson
  AkApplication
  AkService

pub fun actor-kind/show( a : actor-kind ) : string
  match a
    AkPerson      -> "Person"
    AkApplication -> "Application"
    AkService     -> "Service"

pub fun actor-kind/parse( s : string ) : maybe<actor-kind>
  if s == "Person" then Just(AkPerson)
  elif s == "Application" then Just(AkApplication)
  elif s == "Service" then Just(AkService)
  else Nothing

// AP Object types we represent in the archive.
pub type object-kind
  OkNote
  OkArticle
  OkDocument
  OkAudio
  OkVideo
  OkImage
  OkTombstone

pub fun object-kind/show( o : object-kind ) : string
  match o
    OkNote      -> "Note"
    OkArticle   -> "Article"
    OkDocument  -> "Document"
    OkAudio     -> "Audio"
    OkVideo     -> "Video"
    OkImage     -> "Image"
    OkTombstone -> "Tombstone"

pub fun object-kind/parse( s : string ) : maybe<object-kind>
  if s == "Note" then Just(OkNote)
  elif s == "Article" then Just(OkArticle)
  elif s == "Document" then Just(OkDocument)
  elif s == "Audio" then Just(OkAudio)
  elif s == "Video" then Just(OkVideo)
  elif s == "Image" then Just(OkImage)
  elif s == "Tombstone" then Just(OkTombstone)
  else Nothing

// Guess an object-kind from a media type. PDFs are Document; image/*
// is Image; audio/* is Audio; video/* is Video.
pub fun object-kind/from-media( m : media-type ) : object-kind
  if m.kind == "image" then OkImage
  elif m.kind == "audio" then OkAudio
  elif m.kind == "video" then OkVideo
  else OkDocument

// ----------------------------------------------------------------------
//  Privacy / visibility
// ----------------------------------------------------------------------

pub type privacy
  ItPrivate
  ItUnlisted
  ItFollowers
  ItPublic

pub fun privacy/show( p : privacy ) : string
  match p
    ItPrivate   -> "private"
    ItUnlisted  -> "unlisted"
    ItFollowers -> "followers"
    ItPublic    -> "public"

pub fun privacy/parse( s : string ) : maybe<privacy>
  if s == "private" then Just(ItPrivate)
  elif s == "unlisted" then Just(ItUnlisted)
  elif s == "followers" then Just(ItFollowers)
  elif s == "public" then Just(ItPublic)
  else Nothing

// True iff the item should appear in any federation activity.
pub fun privacy/federates( p : privacy ) : bool
  match p
    ItPrivate -> False
    _         -> True

// True iff the item should be addressed to the public collection.
pub fun privacy/is-public( p : privacy ) : bool
  match p
    ItPublic -> True
    _        -> False

// ----------------------------------------------------------------------
//  ActivityPub activity types we dispatch
// ----------------------------------------------------------------------

pub type activity-kind
  AcCreate
  AcUpdate
  AcDelete
  AcFollow
  AcAccept
  AcReject
  AcLike
  AcAnnounce
  AcAdd
  AcRemove
  AcUndo

pub fun activity-kind/show( a : activity-kind ) : string
  match a
    AcCreate   -> "Create"
    AcUpdate   -> "Update"
    AcDelete   -> "Delete"
    AcFollow   -> "Follow"
    AcAccept   -> "Accept"
    AcReject   -> "Reject"
    AcLike     -> "Like"
    AcAnnounce -> "Announce"
    AcAdd      -> "Add"
    AcRemove   -> "Remove"
    AcUndo     -> "Undo"

pub fun activity-kind/parse( s : string ) : maybe<activity-kind>
  if s == "Create" then Just(AcCreate)
  elif s == "Update" then Just(AcUpdate)
  elif s == "Delete" then Just(AcDelete)
  elif s == "Follow" then Just(AcFollow)
  elif s == "Accept" then Just(AcAccept)
  elif s == "Reject" then Just(AcReject)
  elif s == "Like" then Just(AcLike)
  elif s == "Announce" then Just(AcAnnounce)
  elif s == "Add" then Just(AcAdd)
  elif s == "Remove" then Just(AcRemove)
  elif s == "Undo" then Just(AcUndo)
  else Nothing

// ----------------------------------------------------------------------
//  Storage backend tag for an item's mirror
// ----------------------------------------------------------------------

// What kind of remote stores the bytes for a given mirror.
//   RkUrl       : a plain HTTPS URL we never touch (someone else hosts)
//   RkRclone    : an rclone remote+path (we can read/write it)
//   RkGitAnnex  : a git-annex special-remote name in our local repo
//   RkIpfs      : an IPFS CID (printed as ipfs://CID)
pub type remote-kind
  RkUrl
  RkRclone
  RkGitAnnex
  RkIpfs

pub fun remote-kind/show( r : remote-kind ) : string
  match r
    RkUrl      -> "url"
    RkRclone   -> "rclone"
    RkGitAnnex -> "git-annex"
    RkIpfs     -> "ipfs"

pub fun remote-kind/parse( s : string ) : maybe<remote-kind>
  if s == "url" then Just(RkUrl)
  elif s == "rclone" then Just(RkRclone)
  elif s == "git-annex" then Just(RkGitAnnex)
  elif s == "ipfs" then Just(RkIpfs)
  else Nothing

// ----------------------------------------------------------------------
//  AP constants
// ----------------------------------------------------------------------

// The Public collection. Spec mandates accepting all three forms; we
// canonicalise outbound to the full IRI.
pub val ap-public-iri : string = "https://www.w3.org/ns/activitystreams#Public"
pub val ap-public-short : string = "Public"
pub val ap-public-asprefix : string = "as:Public"

pub fun is-public-iri( s : string ) : bool
  s == ap-public-iri || s == ap-public-short || s == ap-public-asprefix

// The two contexts we always embed. Order matters for compactness with
// existing servers (Mastodon canonicalises this exact ordering).
pub val ap-context-activitystreams : string = "https://www.w3.org/ns/activitystreams"
pub val ap-context-security        : string = "https://w3id.org/security/v1"
