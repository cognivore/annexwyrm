// annexwyrm/web/handler/nodeinfo — /.well-known/nodeinfo + /nodeinfo/2.1

module web/handler/nodeinfo

import core/json
import effects/db
import effects/config
import ap/nodeinfo
import web/server

pub fun handle-nodeinfo-discovery( req : request ) : <config,div|e> response
  ok-json(json/show(discovery-doc(get-base-url())))

pub fun handle-nodeinfo( req : request ) : <db,config,div|e> response
  val total = query("SELECT COUNT(*) FROM actor WHERE local = 1", []).first-int.default(0)
  val items = query("SELECT COUNT(*) FROM item WHERE privacy IN ('public','followers','unlisted')",
                    []).first-int.default(0)
  val doc = nodeinfo-doc(
    total-users        = total,
    active-month       = total,
    active-half-year   = total,
    local-items        = items,
    open-registrations = False
  )
  ok-json(json/show(doc))
