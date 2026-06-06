// annexwyrm/annex/publish — the pure projection of an `annex-item` onto
// an AP `ap-object`, plus the file-publication transition.
//
// In the single-tenant model there are no privacy transitions: every item
// is always public and federates immediately on upload. The ONLY gate is
// the file blob (`file-published`), flipped by the publish-file flow in
// `web/handler/item`. `publish-file-item` is the pure state change that
// records the minted URLs; the effectful copy + emit lives in the handler.

module annex/publish

import core/types
import ap/addressing
import ap/object
import annex/item

// Turn an item into the AP object the outbox will wrap in `Create`/`Update`.
// `followers-url` is the owner actor's followers collection URL.
//
// Every item is public, so the audience is always `ItPublic`
// (`to=[Public], cc=[followers]`).
//
// We federate every item as a **Note** — the universally-rendered AS2 post
// type. Mastodon (and most of the fediverse) only displays Note/Article as
// posts; a top-level `Document`/`Audio`/`Video`/`Image` object is ingested
// but shown as "No posts here". Our items are reviews (text) of a media
// piece (file), which is exactly a Note whose body is the review and whose
// optional attachment is the file. The internal object-kind still drives our
// OWN UI; this is only the federated projection.
//
// The title is folded into `content` (Mastodon renders `content`, not `name`
// for a Note) so it stays visible. The PUBLISHED file rides in `attachment`
// (a Document), NOT `url[]` — url[] is only emitted for file-kinds and we are
// now a Note, and an attachment is what Mastodon renders as a downloadable
// file. Archived items carry NO attachment — the private blob never leaks;
// a public data link federates only once the file is published.
//
// `tags` are the item's hashtags (normalised, no '#'); they live in a side
// table, so the caller threads them in (the annex-item value struct stays
// untouched — no extra positional field / koka#654 site). Default [] keeps
// existing call sites compiling unchanged.
pub fun item-to-ap-object( i : annex-item, followers-url : url, tags : list<string> = [] ) : ap-object
  val (to, cc) = build-addressing(ItPublic, followers-url, [])
  // The title and the "review of <url>" reference are folded into the Note's
  // content. We deliberately DO NOT set `inReplyTo`: an annexwyrm review is a
  // standalone post that *references* a resource, not an ActivityStreams
  // reply to another fediverse post. Setting inReplyTo to a non-AP URL (e.g.
  // a cubecobra page) made Mastodon flag the status reply=true with an
  // unresolvable parent, which hides it from the profile's "Posts" tab
  // (verified via social.doma.dev's API). The reference lives in the body.
  val title-html = if i.name == "" then "" else "<p><strong>" ++ i.name ++ "</strong></p>\n"
  val reviewof-html = if i.in-reply-to == "" then ""
    else "<p>review of <a href=\"" ++ i.in-reply-to ++ "\">" ++ i.in-reply-to ++ "</a></p>\n"
  Ap-object(
    id            = i.id,
    kind          = OkNote,
    attributed-to = i.owner,
    name          = i.name,
    summary       = i.summary,
    content       = title-html ++ reviewof-html ++ i.content,
    media-type    = "",
    urls          = [],
    in-reply-to   = "",
    published     = i.published-at,
    updated       = if i.updated-at == i.published-at then "" else i.updated-at,
    to            = to,
    cc            = cc,
    sensitive     = i.summary != "",
    attachment    = file-attachments(i),
    rating        = i.rating,
    tags          = tags
  )

// The federated `attachment` list: the published download as an AS2 Document
// (so a Mastodon post shows a downloadable file). Archived ⇒ [] (the private
// blob never federates). This is where a PUBLIC data link enters federated
// data — the user's invariant: public file ⇒ in the federated object.
fun file-attachments( i : annex-item ) : list<ap-link>
  if !i.file-published || i.file-public-url == "" then []
  else [Ap-link(
    href       = i.file-public-url,
    media-type = i.media-type,
    name       = if i.name == "" then "download" else i.name,
    rel        = ""
  )]

// The AP `url[]` payload for an item, derived purely from its
// file-publication state. Archived ⇒ []; published ⇒ the download link
// (uc?export=download) then the viewer mirror (open?id). In the hermetic
// single-URL case both URLs are equal and the encoder collapses them to
// one Link, which is fine — the `download` href is what the suite asserts.
pub fun file-publication-links( i : annex-item ) : list<ap-link>
  if !i.file-published then []
  else
    val dl = Ap-link(
      href       = i.file-public-url,
      media-type = i.media-type,
      name       = "download",
      rel        = ""
    )
    if i.file-view-url == "" || i.file-view-url == i.file-public-url then [dl]
    else
      val view = Ap-link(
        href       = i.file-view-url,
        media-type = i.media-type,
        name       = "view",
        rel        = ""
      )
      [dl, view]

// ----------------------------------------------------------------------
//  File-publication transition (pure)
// ----------------------------------------------------------------------

// Flip an item's blob from archived to published, recording the minted
// download + viewer URLs and advancing `updated-at`. The item itself was
// already public; this only opens the file. The effectful steps (copy to
// the public remote, mint the URL, save, emit Update) live in the handler.
// `remotes` is passed explicitly (the caller appends the public mirror) so
// the whole construction is a single positional `Annex-item` literal — no
// record-update, which keeps koka#654's value-struct-in-lambda panic clear.
pub fun publish-file-item(
    i : annex-item, public-url : url, view-url : url, now : iso-time,
    remotes : list<item-remote>
  ) : annex-item
  Annex-item(
    i.id, i.owner, i.kind,
    i.name, i.summary, i.content, i.media-type,
    i.byte-size, i.sha256-hex,
    i.rating, i.in-reply-to,
    True, public-url, view-url,
    i.published-at, now,
    remotes
  )

// Apply a metadata edit to a review, advancing `updated-at`. Only the
// human-authored fields change — title, abstract/CW, body HTML, rating,
// and the review-of target. The file blob and ALL of its publication
// state (`file-published`, the minted URLs, the mirror remotes, the byte
// size + hash) carry through untouched: editing the review text must
// never republish or retract the file. Positional literal (no
// record-update) to keep koka#654's value-struct-in-lambda panic clear,
// exactly like `publish-file-item` above.
pub fun edit-item-fields(
    i : annex-item, name : string, summary : string, content : string,
    rating : int, in-reply-to : url, now : iso-time
  ) : annex-item
  Annex-item(
    i.id, i.owner, i.kind,
    name, summary, content, i.media-type,
    i.byte-size, i.sha256-hex,
    rating, in-reply-to,
    i.file-published, i.file-public-url, i.file-view-url,
    i.published-at, now,
    i.remotes
  )
