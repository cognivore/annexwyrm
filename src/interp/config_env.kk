// annexwyrm/interp/config_env — Config → environment variables.
//
// One-shot read at handler installation time; all six fields are
// captured in closures. No re-read of the environment during a
// request — restart the daemon to change settings.

module interp/config_env

import std/os/env
import effects/config

// Read config values out of the environment. Defaults are filled in for
// development convenience but production callers should set everything.
pub fun with-env-config( action : () -> <config,ndet|e> a ) : <ndet|e> a
  val domain      = env-or-default("ANNEXWYRM_DOMAIN",    "annexwyrm.local")
  val base-url    = env-or-default("ANNEXWYRM_BASE_URL",  "https://" ++ domain)
  val data-dir    = env-or-default("ANNEXWYRM_DATA",      "./data")
  val username    = env-or-default("ANNEXWYRM_USERNAME",  "alice")
  val manual      = env-or-default("ANNEXWYRM_MANUAL_APPROVE", "0") != "0"
  val name        = env-or-default("ANNEXWYRM_INSTANCE_NAME", "annexwyrm")
  val archive-rem = env-or-default("ANNEXWYRM_ARCHIVE_REMOTE", "gdrive-crypt:annexwyrm")
  val public-rem  = env-or-default("ANNEXWYRM_PUBLIC_REMOTE",  "gdrive:annexwyrm-public")
  // No env-or-default: an EMPTY base must stay empty (the "use rclone link"
  // sentinel). env-or-default would not help anyway — the default IS "".
  val url-base    = match get-env-value("ANNEXWYRM_PUBLIC_URL_BASE")
                      Just(v) -> v
                      Nothing -> ""
  with handler
    fun get-domain()             domain
    fun get-base-url()           base-url
    fun get-data-dir()           data-dir
    fun get-local-username()     username
    fun get-manually-approves()  manual
    fun get-instance-name()      name
    fun get-archive-remote()     archive-rem
    fun get-public-remote()      public-rem
    fun get-public-url-base()    url-base
  action()

fun env-or-default( key : string, dflt : string ) : ndet string
  match get-env-value(key)
    Just(v) | v != "" -> v
    _                 -> dflt
