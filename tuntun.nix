# Expose annexwyrm publicly through tuntun so it can federate.
#
# Run `tuntun .` from this directory. tuntun registers the subdomain,
# provisions DNS (Porkbun) + Caddy + ACME on your tuntun-server, and tunnels
# the daemon's HTTP port to the public URL below.
#
# Public URL : https://annexwyrm.sweater.fere.me
# Handle     : @sweater@annexwyrm.sweater.fere.me
#
# auth = "public" (NOT "tenant" like relay-rook): an ActivityPub server's
# actor / inbox / .well-known/webfinger MUST be fetchable by remote servers
# with no auth wall, or federation cannot bootstrap. annexwyrm's OWN login
# still gates uploads/publishing; private items remain 404 to anonymous
# visitors. The public archive index is world-readable by design.
#
# `localPort` MUST match `services.annexwyrm.tunnelPort` in the home-manager
# config — that is the cleartext Caddy site fronting the daemon's Unix
# socket (the daemon itself speaks only a Unix socket, which tuntun cannot
# tunnel directly).

{ tuntun, ... }:

tuntun.mkProject {
  tenant = "sweater";
  domain = "fere.me";

  services = {
    annexwyrm = {
      subdomain = "annexwyrm";
      localPort = 8730;
      auth      = "public";
      healthCheck = {
        path           = "/";
        timeoutSeconds = 5;
      };
    };
  };
}
