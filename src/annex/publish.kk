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
// (`to=[Public], cc=[followers]`). The `url[]` is built from the item's
// file-publication state, NOT from any per-mirror flag: archived items
// (`file-published=False`) carry an EMPTY url[] — nothing about the blob
// leaks — and published items carry the download URL (uc?export=download)
// first and the viewer mirror (open?id) second.
pub fun item-to-ap-object( i : annex-item, followers-url : url ) : ap-object
  val (to, cc) = build-addressing(ItPublic, followers-url, [])
  Ap-object(
    id            = i.id,
    kind          = i.kind,
    attributed-to = i.owner,
    name          = i.name,
    summary       = i.summary,
    content       = i.content,
    media-type    = i.media-type,
    urls          = file-publication-links(i),
    in-reply-to   = i.in-reply-to,
    published     = i.published-at,
    updated       = if i.updated-at == i.published-at then "" else i.updated-at,
    to            = to,
    cc            = cc,
    sensitive     = i.summary != "",
    attachment    = [],
    rating        = i.rating
  )

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
