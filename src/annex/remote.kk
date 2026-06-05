// annexwyrm/annex/remote — turning an `item-remote` into the AP `Link`
// we put inside `url[]`.

module annex/remote

import core/types
import ap/object
import annex/item

// Convert one mirror row into an AP `Link` object. The mirror's
// `media-type` (when present) overrides the item-wide media type.
pub fun remote-to-link( r : item-remote, item-mediatype : string ) : ap-link
  val href = link-href(r.kind, r.target)
  val mt   = if r.media-type == "" then item-mediatype else r.media-type
  Ap-link(
    href       = href,
    media-type = mt,
    name       = r.label,
    rel        = link-rel-for(r.kind)
  )

// Convert all *published* remotes of an item into the AP url[] payload.
pub fun item-published-links( i : annex-item ) : list<ap-link>
  i.published-remotes.map(fn(r) remote-to-link(r, i.media-type))

// ----------------------------------------------------------------------
//  Per-kind URL/href shaping
// ----------------------------------------------------------------------

// Decide what URL the AP `Link.href` should be. For HTTP/HTTPS URLs we
// hand them through. For rclone / git-annex / IPFS we synthesise a
// URL scheme the way the wider fediverse expects.
fun link-href( kind : remote-kind, target : string ) : string
  match kind
    RkUrl      -> target
    RkIpfs     -> if target.starts-with("ipfs://").bool then target else "ipfs://" ++ target
    RkGitAnnex -> "git-annex://" ++ target
    RkRclone   -> "rclone://" ++ target

// Standard `rel` values for non-HTTP mirrors.
fun link-rel-for( kind : remote-kind ) : string
  match kind
    RkIpfs     -> "alternate"
    RkGitAnnex -> "alternate"
    RkRclone   -> "alternate"
    RkUrl      -> ""
