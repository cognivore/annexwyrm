// annexwyrm/web/handler/help — GET /help/storage (the storage-setup guide).
//
// Public (no auth): it's documentation. Linked from the settings page's [?].

module web/handler/help

import effects/db
import web/prefs
import web/server
import web/html/help

pub fun handle-help-storage( req : request ) : db response
  ok-html(render-storage-help(get-page-width()))
