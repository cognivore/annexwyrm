// annexwyrm/annex/scan — folder ingest.
//
// Pure: given the list of files we found and the set of SHA-256s
// already in the archive, decide which to ingest and what their item
// records should look like. The actual filesystem walk happens in
// interpreter / shell code.

module annex/scan

import core/types
import annex/item

// One entry from a folder scan.
pub value struct scanned-file
  path       : string         // absolute path on disk
  basename   : string         // last path segment
  byte-size  : int
  sha256-hex : string         // required for dedup
  media-type : string         // sniffed from extension or file
  modified   : iso-time

// True iff this scanned file is *not* already in the archive (matched
// by content hash, ignoring filename).
pub fun is-new( f : scanned-file, known-shas : list<string> ) : bool
  !known-shas.any(fn(s) s == f.sha256-hex)

// Filter a scan list down to the ones that should be ingested.
pub fun pick-new( fs : list<scanned-file>, known-shas : list<string> ) : list<scanned-file>
  fs.filter(fn(f) is-new(f, known-shas))

// Convert a scanned file into a fresh AnnexItem.
pub fun ingest-as( f : scanned-file, id : url, owner : url, now : iso-time ) : annex-item
  val kind = guess-kind(f.media-type)
  fresh-item(id, owner, kind, f.basename, f.media-type, f.byte-size, f.sha256-hex, now)

fun guess-kind( media : string ) : object-kind
  match media-type/parse(media)
    Just(mt) -> object-kind/from-media(mt)
    Nothing  -> OkDocument
