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
        default = null;
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
        docker-compose.volumes = {
          postgres-data = { };
          redis-data = { };
          mastodon-data = { };
        };
        services = {
          mastodon = { pkgs, ... }: {
            service = {
              restart = "always";
              volumes = [
                "postgres-data:/var/lib/postgres/data"
                "redis-data:/var/lib/redis"
                "mastodon-data:/var/lib/mastodon"
              ] ++ (map (env-file: "${env-file}:${env-file}:ro,Z")
                cfg.environment-files);
              ports = [ "${toString cfg.port}:80" ];
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
                      passwordFile = mkIf (!isNull cfg.smtp.password-file)
                        cfg.smtp.password-file;
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
      commonHttpConfig = ''
        log_format with_response_time '$remote_addr - $remote_user [$time_local] '
                     '"$request" $status $body_bytes_sent '
                     '"$http_referer" "$http_user_agent" '
                     '"$request_time" "$upstream_response_time"';
        access_log /var/log/nginx/access.log with_response_time;
      '';
      recommendedTlsSettings = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      virtualHosts."${cfg.hostname}" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}/";
          proxyWebsockets = true;
          recommendedProxySettings = true;
        };
      };
    };
  };
}
