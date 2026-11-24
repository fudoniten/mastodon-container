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

    allow-registrations = mkOption {
      type = bool;
      description = "Enable the creation of new accounts.";
      default = true;
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
        networks.external_network.internal = false;
        services = {
          mastodon = { pkgs, ... }: {
            service = {
              restart = "always";
              volumes = [
                "postgres-data:/var/lib/postgresql"
                # services.redis.servers.mastodon keeps its dump in
                # /var/lib/redis-mastodon, not /var/lib/redis, so the old
                # mount point persisted nothing and Sidekiq's queues
                # (retries, scheduled jobs) vanished with every restart.
                "redis-data:/var/lib/redis-mastodon"
                "mastodon-data:/var/lib/mastodon"
              ] ++ (map (env-file: "${env-file}:${env-file}:ro,Z")
                cfg.environment-files);
              # Loopback only: the host nginx below proxies to 127.0.0.1, and
              # a podman-published port bypasses the host firewall.
              ports = [ "127.0.0.1:${toString cfg.port}:80" ];
              networks = [ "external_network" ];
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
                    extraConfig.registrations_open =
                      if cfg.allow-registrations then "true" else "false";
                  };
                  nginx = {
                    recommendedTlsSettings = true;
                    recommendedGzipSettings = true;
                    recommendedOptimisation = true;
                    recommendedProxySettings = true;
                    commonHttpConfig = ''
                      log_format with_response_time '$remote_addr - $remote_user [$time_local] '
                                   '"$request" $status $body_bytes_sent '
                                   '"$http_referer" "$http_user_agent" '
                                   '"$request_time" "$upstream_response_time"';
                      access_log /var/log/nginx/access.log with_response_time;
                    '';
                    # Must match the stock module's vhost name (localDomain),
                    # or these overrides land on a second, unused vhost.
                    virtualHosts."${cfg.domain}" = {
                      forceSSL = false;
                      enableACME = false;
                      # Mastodon accepts uploads up to 99MB (video); the
                      # nginx default of 10m turns those into 413s.
                      extraConfig = "client_max_body_size 100m;";
                      locations = let
                        mkCacheLine = { maxAge ? 2419200, immutable ? false }:
                          let
                            immutableString = if immutable then
                              "immutable"
                            else
                              "must-revalidate";
                          in {
                            extraConfig = ''
                              add_header Cache-Control "public, max-age=${
                                toString maxAge
                              }, ${immutableString}";
                              add_header Strict-Transport-Security "max-age=63072000; includeSubDomains";
                              try_files $uri =404;
                            '';
                          };
                      in {
                        "/api/v1/streaming" = {
                          extraConfig = ''
                            proxy_set_header X-Forwarded-Proto $scheme;
                            proxy_buffering off;
                            proxy_redirect off;
                            add_header Strict-Transport-Security "max-age=63072000; includeSubDomains";
                            tcp_nodelay on;
                          '';

                        };
                        "@proxy" = {
                          # TLS ends at the host nginx, so $scheme in here is
                          # always "http". The recommended headers include
                          # `X-Forwarded-Proto $scheme`, which nginx sends as a
                          # second header *after* the one below; Rack 3 trusts
                          # the last value, Rails' force_ssl sees "http", and
                          # every request 301s back to https://<domain>/ in a
                          # loop. So turn the include off here and set the
                          # same headers by hand, with the proto pinned.
                          recommendedProxySettings = false;
                          extraConfig = ''
                            proxy_set_header Host $host;
                            proxy_set_header X-Real-IP $remote_addr;
                            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                            proxy_set_header X-Forwarded-Proto https; # NOTE: Lie and say we're on HTTPS! Otherwise Mastodon will refuse to serve.
                            proxy_set_header X-Forwarded-Host $host;
                            proxy_set_header X-Forwarded-Server $hostname;
                            proxy_pass_header Server;

                            proxy_buffering on;
                            proxy_redirect off;

                            ## TODO: consider uncommentingq
                            # proxy_cache CACHE;
                            # proxy_cache_valid 200 7d;
                            # proxy_cache_valid 410 24h;
                            # proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
                            # add_header X-Cached $upstream_cache_status;

                            tcp_nodelay on;
                          '';
                        };

                        # These used to be keyed "^/assets/" etc. with no "~",
                        # which nginx reads as literal prefixes that never
                        # match, so none of this caching applied. /system/
                        # (uploaded media) is left to the stock module's
                        # alias location: a try_files under the package's
                        # public/ root would 404 it.
                        "/sw.js" = mkCacheLine { maxAge = 604800; };
                        "~ ^/assets/" = mkCacheLine { };
                        "~ ^/avatars/" = mkCacheLine { };
                        "~ ^/emoji/" = mkCacheLine { };
                        "~ ^/headers/" = mkCacheLine { };
                        "~ ^/packs" = mkCacheLine { };
                        "~ ^/sounds/" = mkCacheLine { };
                      };
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
      virtualHosts."${cfg.hostname}" = {
        enableACME = true;
        forceSSL = true;
        extraConfig = "client_max_body_size 100m;";
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}/";
          proxyWebsockets = true;
          recommendedProxySettings = true;
        };
      };
    };
  };
}
