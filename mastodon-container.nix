{ config, lib, pkgs, ... }@toplevel:

with lib;
let cfg = config.services.mastodonContainer;
in {

  options.services.mastodonContainer = with types; {
    enable = mkEnableOption "Enable Mastodon running in an Arion container.";

    domain = mkOption {
      type = str;
      description = "Domain name of this Mastodon instance.";
    };

    hostname = mkOption {
      type = str;
      description = "Hostname of the Mastodon server.";
      default = toplevel.config.services.mastodonContainer.domain;
    };

    state-directory = mkOption {
      type = str;
      description = "Port at which to store server data.";
    };

    port = mkOption {
      type = port;
      description = "Port at which to serve Mastodon web requests.";
      default = 55001;
    };

    environment-files = mkOption {
      type = listOf str;
      description =
        "List of files with env variables to set for the Mastodon job.";
      default = [ ];
    };

    streaming-processes = mkOption {
      type = int;
      description =
        "Number of processes to use for Mastodon streaming. Recommended is (#cores - 1).";
      default = 4;
    };

    smtp = {
      host = mkOption {
        type = str;
        description = "Outgoing SMTP server.";
      };

      port = mkOption {
        type = port;
        description = "Outgoing SMTP server port.";
        default = 25;
      };

      user = mkOption {
        type = str;
        description = "User as which to authenticate to the SMTP server.";
        default = "mastodon";
      };

      password-file = mkOption {
        type = nullOr str;
        description = "Path to file containing SMTP password";
      };

      from-address = mkOption {
        type = str;
        description = "Address from which to send outgoing mail.";
        default =
          "${toplevel.config.services.mastodonContainer.smtp.user}@${toplevel.config.services.mastodonContainer.domain}";
      };
    };
  };

  config = mkIf cfg.enable {
    virtualisation.arion.projects.mastodon.settings = let
      image = { pkgs, ... }: {
        project.name = "mastodon";
        services = {
          mastodon = { pkgs, ... }: {
            service = {
              restart = "always";
              volumes = [
                "postgres-data:/var/lib/postgres/data"
                "redis-data:/var/lib/redis"
                "mastodon-data:/var/lib/mastodon"
              ];
            };
            nixos = {
              useSystemd = true;
              configuration = {
                boot.tmp.useTmpfs = true;
                system.nssModules = mkForce [ ];
                services = {
                  nscd.enable = false;
                  postgresql.enable = true;
                  mastodon = {
                    enable = true;
                    webPort = cfg.port;
                    localDomain = cfg.domain;
                    extraEnvFiles = cfg.environment-files;
                    smtp = {
                      inherit (cfg.smtp) host port user;
                      fromAddress = cfg.smtp.from-address;
                      authenticate = !isNull cfg.smtp.password-file;
                      passwordFile = cfg.smtp.password-file;
                    };
                    redis.createLocally = true;
                    database.createLocally = true;
                    configureNginx = true;
                    automaticMigrations = true;
                    streamingProcesses = cfg.streaming-processes;
                  };
                  nginx = {
                    virtualHosts."${cfg.hostname}" = {
                      forceSSL = false;
                      enableACME = false;
                    };
                  };
                };
              };
            };
          };
        };
      };
    in { imports = [ image ]; };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts."${cfg.hostname}" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://localhost:${toString cfg.port}";
          proxyWebsockets = true;
        };
      };
    };
  };
}
