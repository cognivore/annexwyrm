# Home-manager module exposed as `homeManagerModules.default` so the
# nixvana flake (`~/Github/nixvana/home-manager/flake.nix`) can mount us
# the same way it mounts `zensurance.homeManagerModules.default`,
# `mirror-gallery.homeManagerModules.default`, etc.
#
# Usage from septnesis/home.nix (mirrors `services.zensurance`):
#
#   services.annexwyrm = {
#     enable    = true;
#     domain    = "annexwyrm.localhost";
#     socket    = "${config.home.homeDirectory}/.local/share/annexwyrm/sock";
#     dataDir   = "${config.home.homeDirectory}/.local/share/annexwyrm";
#     username  = "alice";
#   };
#
# The module:
#   1. emits `~/Caddy/sites/annexwyrm.Caddyfile` via `home.file`, which
#      music-box's `import sites/*.Caddyfile` picks up on next reload;
#   2. installs the daemon binary onto `home.packages`;
#   3. provisions the data dir + runs `annexwyrm init` once on activation;
#   4. registers a launchd agent that runs `annexwyrm serve` against the
#      configured socket.
#
# Activation order: home.activation runs after home.file is linked, so
# the daemon's first start happens after the Caddyfile is in place.

self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.annexwyrm;
  inherit (lib) mkEnableOption mkOption mkIf types literalExpression;

  # The site definition Caddy actually loads. Path is absolute so the
  # daemon and Caddy agree on which Unix socket to share.
  caddyfile = pkgs.writeText "annexwyrm.Caddyfile" ''
    http://${cfg.domain} {
        encode zstd gzip
        # Caddyfile blocks require the `{` to end the line — `request_body {
        # max_size 4GB }` on one line is a parse error ("Unexpected next
        # token after '{' on same line"). Keep the block multi-line.
        request_body {
            max_size 4GB
        }
        reverse_proxy unix/${cfg.socket} {
            header_up X-Forwarded-Host {host}
            header_up X-Forwarded-Proto {scheme}
            transport http {
                versions 1.1
                read_buffer 64KB
                write_buffer 64KB
            }
        }
        # Static assets ship inside the package's read-only store path, not
        # the mutable data dir: `annexwyrm init` provisions the db + keypair
        # under dataDir but deliberately does NOT copy `static/` there, and
        # the daemon has no /static route (the route table's catch-all 404s).
        # Serving from ${cfg.package}/share/annexwyrm/static keeps the CSS
        # version-locked to the binary with no copy step and no staleness.
        handle_path /static/* {
            root * ${cfg.package}/share/annexwyrm/static
            file_server
        }
        log {
            output file ${config.home.homeDirectory}/Caddy/logs/annexwyrm.log
            format json
        }
    }
  '';

  # Actor identity + data location, exported into the daemon's launchd
  # environment so `init` and `serve` (both run by serveScript below) agree
  # on who the local actor is. The original bug: init ran with none of
  # these set, so it minted the config_env default actor
  # (alice@annexwyrm.local, https) while the daemon served
  # sweater@annexwyrm.localhost — login then failed (no matching actor row,
  # and local_login's FK to actor(id) silently rejected the password row).
  appEnv = {
    ANNEXWYRM_DOMAIN        = cfg.domain;
    ANNEXWYRM_BASE_URL      = "http://${cfg.domain}";
    ANNEXWYRM_USERNAME      = cfg.username;
    ANNEXWYRM_INSTANCE_NAME = cfg.instanceName;
    ANNEXWYRM_SOCKET        = cfg.socket;
    ANNEXWYRM_DATA          = cfg.dataDir;
  };

  # The daemon launcher. Resolves the login password from rageveil at every
  # (re)start — the same "resolve secrets at service start" pattern
  # services.zensurance uses, keeping the secret out of the nix store — then
  # runs the idempotent `init` (mint the actor if absent, upsert the login
  # password row) and exec's `serve`. The identity env above reaches this
  # script through the launchd agent's EnvironmentVariables.
  serveScript = pkgs.writeShellScript "annexwyrm-serve" ''
    set -euo pipefail
    mkdir -p ${lib.escapeShellArg cfg.dataDir}
    ${lib.optionalString (cfg.passwordSecret != null && cfg.rageveilPackage != null) ''
      if pw="$(${cfg.rageveilPackage}/bin/rageveil show ${lib.escapeShellArg cfg.passwordSecret} 2>/dev/null)"; then
        export ANNEXWYRM_PASSWORD="$pw"
      else
        echo "annexwyrm: WARNING: could not resolve '${cfg.passwordSecret}' from rageveil; form login disabled until fixed" >&2
      fi
    ''}
    ${cfg.package}/bin/annexwyrm init ${lib.escapeShellArg cfg.dataDir}
    exec ${cfg.package}/bin/annexwyrm serve
  '';
in
{
  options.services.annexwyrm = {
    enable = mkEnableOption "annexwyrm — federated git-annex archive (Koka)";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = literalExpression "annexwyrm.packages.\${system}.default";
      description = "The annexwyrm binary derivation.";
    };

    domain = mkOption {
      type = types.str;
      default = "annexwyrm.localhost";
      description = "Hostname Caddy will reverse-proxy to the daemon.";
    };

    socket = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.local/share/annexwyrm/sock";
      description = "Unix socket the daemon listens on and Caddy proxies to.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.local/share/annexwyrm";
      description = "SQLite db, blob staging, RSA keypair live here.";
    };

    username = mkOption {
      type = types.str;
      default = "alice";
      description = "Preferred username of the single local AP actor.";
    };

    instanceName = mkOption {
      type = types.str;
      default = "annexwyrm";
      description = "Friendly name shown in the HTML chrome.";
    };

    passwordSecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "annexwyrm.localhost/sweater/password";
      description = ''
        rageveil entry path holding the login password. Resolved with
        `rageveil show` at every daemon (re)start and applied to the local
        actor's login row, so the secret never lands in the nix store.
        Requires `rageveilPackage`. When null, no password is set and the
        login form cannot authenticate.
      '';
    };

    rageveilPackage = mkOption {
      type = types.nullOr types.package;
      default = null;
      defaultText = literalExpression "pkgs.rageveil";
      description = ''
        The rageveil package used to resolve `passwordSecret` at runtime.
        Mirrors `services.zensurance.rageveilPackage`.
      '';
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];

    # The site config lives where music-box's top-level Caddyfile imports
    # from: `import sites/*.Caddyfile` in `~/Caddy/Caddyfile`. We drop our
    # file there; a Caddy reload picks it up.
    home.file."Caddy/sites/annexwyrm.Caddyfile".source = caddyfile;

    # Ensure the data dir exists before launchd starts the agent: launchd
    # opens StandardOut/ErrorPath (daemon.log/err under dataDir) when it
    # spawns the job and will not create parent dirs itself. Actor minting
    # and the rageveil password now happen in serveScript at agent start.
    home.activation.annexwyrmDataDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p ${cfg.dataDir}
    '';

    # The daemon itself.  Standard launchd-agent shape used elsewhere in
    # the nixvana fleet (mirror-gallery, mighty-rearranger, etc.). Runs via
    # serveScript so the rageveil password is resolved at every start.
    launchd.agents.annexwyrm = {
      enable = true;
      config = {
        ProgramArguments = [ "${serveScript}" ];
        EnvironmentVariables = appEnv // {
          HOME = config.home.homeDirectory;
          PATH = "${cfg.package}/bin:${pkgs.rclone}/bin:${pkgs.git-annex}/bin:/usr/bin:/bin";
        };
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${cfg.dataDir}/daemon.log";
        StandardErrorPath = "${cfg.dataDir}/daemon.err";
        WorkingDirectory = cfg.dataDir;
      };
    };
  };
}
