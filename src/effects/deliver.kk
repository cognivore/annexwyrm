// annexwyrm/effects/deliver — outbound HTTP POST for federation.
//
// Separate from `fetch` so the queue/retry policy that wraps
// federation deliveries doesn't accidentally apply to plain GETs.

module effects/deliver

import effects/http

pub effect deliver
  // POST `body` to `url` with the headers already filled in (Date,
  // Digest, Signature, Content-Type). The interpreter does not add
  // anything; the algorithm built every header. Returns the response or
  // a synthetic 5xx on transport failure.
  fun http-post( url : string, headers : list<(string,string)>, body : string ) : http-response
