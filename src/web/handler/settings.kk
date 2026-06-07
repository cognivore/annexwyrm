// annexwyrm/web/handler/settings — GET/POST /settings (owner-only).
//
// v1 has a single setting: the responsiveness mode (container max-width),
// persisted in the `setting` table via web/prefs and applied site-wide by
// layout. The POST validates against the closed set of modes — the stored
// value is later emitted inside a <style> block, so nothing free-form may
// ever be persisted.

module web/handler/settings

import core/url
import effects/db
import effects/config
import web/prefs
import web/server
import web/html/settings
import web/handler/item   // is-owner-session

pub fun handle-settings-form( req : request ) : <db,config,div|e> response
  if !is-owner-session(req) then forbidden("login required")
  else
    val w = get-page-width()
    val saved = req.query.contains("saved=1")
    ok-html(render-settings-form(w, saved, w))

pub fun handle-settings-post( req : request ) : <db,config,div|e> response
  if !is-owner-session(req) then forbidden("login required")
  else
    val w = query-parse(req.body).filter(fn(p) p.fst == "width").head
      .map(fn(p) p.snd).default("")
    if !valid-width(w) then bad-request("invalid width mode")
    else
      set-page-width(w)
      see-other("/settings?saved=1")
