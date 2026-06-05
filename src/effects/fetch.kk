// annexwyrm/effects/fetch — outbound HTTP GET.
//
// Resolves remote actors, dereferences AP objects we receive references
// to. We keep this orthogonal to `deliver` (POST) so an interpreter can
// add caching to one without touching the other.

module effects/fetch

import effects/http

pub effect fetch
  // Fetch `url` with the supplied accept-header (typically
  // "application/activity+json, application/ld+json"). Times out per
  // interpreter policy.
  fun http-get( url : string, accept : string ) : http-response
