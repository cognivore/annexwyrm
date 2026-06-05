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
        request_body { max_size 4GB }
        reverse_proxy unix/${cfg.socket} {
            header_up X-Forwarded-Host {host}
            header_up X-Forwarded-Proto {scheme}
            transport http {
                versions 1.1
                read_buffer 64KB
                write_buffer 64KB
            }
        }
        handle_path /static/* {
            root * ${cfg.dataDir}/static
            file_server
        }
        log {
            output file ${config.home.homeDirectory}/Caddy/logs/annexwyrm.log
            format json
        }
    }
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

    # `secrets` follows the same shape as `services.zensurance.secrets`
    # — resolve through rageveil at every service start.  TODO: wire the
    # ANNEXWYRM_PASSWORD path through rageveil instead of hardcoding.
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];

    # The site config lives where music-box's top-level Caddyfile imports
    # from: `import sites/*.Caddyfile` in `~/Caddy/Caddyfile`. We drop our
    # file there; a Caddy reload picks it up.
    home.file."Caddy/sites/annexwyrm.Caddyfile".source = caddyfile;

    # Provision the data dir + run `annexwyrm init` exactly once. The
    # `[ -f ]` guard makes the activation idempotent.
    home.activation.annexwyrmInit = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p ${cfg.dataDir}
      if [ ! -f ${cfg.dataDir}/annexwyrm.db ]; then
        $DRY_RUN_CMD ${cfg.package}/bin/annexwyrm init ${cfg.dataDir}
      fi
    '';

    # The daemon itself.  Standard launchd-agent shape used elsewhere in
    # the nixvana fleet (mirror-gallery, mighty-rearranger, etc.).
    launchd.agents.annexwyrm = {
      enable = true;
      config = {
        ProgramArguments = [ "${cfg.package}/bin/annexwyrm" "serve" ];
        EnvironmentVariables = {
          ANNEXWYRM_DOMAIN = cfg.domain;
          ANNEXWYRM_BASE_URL = "http://${cfg.domain}";
          ANNEXWYRM_USERNAME = cfg.username;
          ANNEXWYRM_INSTANCE_NAME = cfg.instanceName;
          ANNEXWYRM_SOCKET = cfg.socket;
          ANNEXWYRM_DATA = cfg.dataDir;
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
