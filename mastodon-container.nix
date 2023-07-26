{ config, lib, pkgs, ... }@toplevel:

with lib;
let
  cfg = config.services.mastodonContainer;

  proxyConf = pkgs.writeText "mastodon-nginx.conf" ''
    http {
      upstream backend {
        server web:3000 fail_timeout=0;
      }

      upstream streaming {
        server streaming:4000 fail_timeout=0;
      }

      proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=CACHE:10m inactive=7d max_size=1g;

      server {
        listen 3000;
        server_name localhost;
        server_tokens off;

        gzip on;
        gzip_disable "msie6";
        gzip_vary on;
        gzip_proxied any;
        gzip_comp_level 6;
        gzip_buffers 16 8k;
        gzip_http_version 1.1;
        gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
        add_header Strict-Transport-Security "max-age=31536000" always;

        location / {
          try_files $uri @proxy;
        }

        location ~ ^/(emoji|packs|system/accounts/avatars|system/media_attachments/files) {
          add_header Cache-Control "public, max-age=31536000, immutable";
          add_header Strict-Transport-Security "max-age=31536000" always;
          try_files $uri @proxy;
        }

        location /sw.js {
          add_header Cache-Control "public, max-age=0";
          add_header Strict-Transport-Security "max-age=31536000" always;
          try_files $uri @proxy;
        }

        location @proxy {
          proxy_set_header Host $host;
          proxy_set_header Proxy "";
          proxy_pass_header Server;
          proxy_pass http://backend;
          proxy_buffering on;
          proxy_redirect off;
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "upgrade";
          proxy_cache CACHE;
          proxy_cache_valid 200 7d;
          proxy_cache_valid 410 24h;
          proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
          add_header X-Cached $upstream_cache_status;
          add_header Strict-Transport-Security "max-age=31536000" always;
          tcp_nodelay on;
        }

        location /api/v1/streaming {
          proxy_set_header Host $host;
          proxy_set_header Proxy "";
          proxy_pass http://streaming;
          proxy_buffering off;
          proxy_redirect off;
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
          tcp_nodelay on;
        }
      }
    }
  '';

in {
  options.services.mastodonContainer = with types; {
    enable = mkEnableOption "Enable Mastodon running in an Arion container.";

    version = mkOption {
      type = str;
      description = "Version of Mastodon to launch.";
    };

    images = {
      mastodon = mkOption {
        type = str;
        description = "Docker image to use for Mastodon.";
        default =
          "ghcr.io/mastodon/mastodon:${toplevel.config.services.mastodonContainer.version}";
      };

      postgres = mkOption {
        type = str;
        description = "Docker image to use for PostgreSQL server.";
        default = "postgres:15-alpine";
      };

      redis = mkOption {
        type = str;
        description = "Docker image to use for Redis server.";
        default = "redis:7-alpine";
      };

      nginx = mkOption {
        type = str;
        description = "Docker image to use for Proxy server.";
        default = "nginx:alpine-slim";
      };
    };

    state-directory = mkOption {
      type = str;
      description = "Port at which to store server data.";
    };

    port = mkOption {
      type = port;
      description = "Port at which to serve Mastodon web requests.";
      default = 3000;
    };

    uids = {
      mastodon = mkOption {
        type = int;
        description = "UID as which to run Mastodon.";
        default = 730;
      };
      postgres = mkOption {
        type = int;
        description = "UID as which to run PostgreSQL.";
        default = 731;
      };
      redis = mkOption {
        type = int;
        description = "UID as which to run Redis.";
        default = 732;
      };
    };
  };

  config = mkIf cfg.enable {
    users.users = {
      mastodon = {
        isSystemUser = true;
        group = "mastodon";
        uid = cfg.uids.mastodon;
      };
      mastodon-postgres = {
        isSystemUser = true;
        group = "mastodon";
        uid = cfg.uids.postgres;
      };
      mastodon-redis = {
        isSystemUser = true;
        group = "mastodon";
        uid = cfg.uids.redis;
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.state-directory}/mastodon 0700 mastodon          root - -"
      "d ${cfg.state-directory}/postgres 0700 mastodon-postgres root - -"
      "d ${cfg.state-directory}/redis    0700 mastodon-redis    root - -"
    ];

    virtualisation.arion.projects.mastodon.settings = let
      mkUserMap = uid: "${toString uid}:${toString uid}";
      image = { pkgs, ... }: {
        project.name = "mastodon";
        networks = {
          internal_network.internal = true;
          external_network.internal = false;
        };
        services = {
          proxy.service = {
            image = cfg.images.nginx;
            restart = "always";
            ports = [ "${toString cfg.port}:3000" ];
            volumes = [ "${proxyConf}:/etc/nginx/nginx.conf:ro,Z" ];
            depends_on = [ "web" "streaming" ];
            networks = [ "internal_network" "external_network" ];
          };
          db.service = {
            image = cfg.images.postgres;
            restart = "always";
            volumes =
              [ "${cfg.state-directory}/postgres:/var/lib/postgresql/data" ];
            healthcheck.test = [ "CMD" "pg_isready" "-U" "postgres" ];
            environment.POSTGRES_HOST_AUTH_METHOD = "trust";
            networks = [ "internal_network" ];
            user = mkUserMap cfg.uids.postgres;
          };
          redis.service = {
            image = cfg.images.redis;
            restart = "always";
            volumes = [ "${cfg.state-directory}/redis:/data" ];
            healthcheck.test = [ "CMD" "redis-cli" "ping" ];
            networks = [ "internal_network" ];
            user = mkUserMap cfg.uids.redis;
          };
          web.service = {
            image = cfg.images.mastodon;
            hostname = "mastodon-web";
            restart = "always";
            volumes =
              [ "${cfg.state-directory}/mastodon:/mastodon/public/system" ];
            command = ''
              bash -c "rm -f /mastodon/tmp/pids/server.pid; bundle exec rails s -p 3000"'';
            healthcheck.test = [
              "CMD-SHELL"
              "wget -q --spider --proxy=off localhost:3000/health || exit 1"
            ];
            depends_on = [ "db" "redis" ];
            networks = [ "internal_network" ];
            user = mkUserMap cfg.uids.mastodon;
          };
          streaming.service = {
            image = cfg.images.mastodon;
            hostname = "mastodon-streaming";
            restart = "always";
            command = "node ./streaming";
            healthcheck.test = [
              "CMD-SHELL"
              "wget -q --spider --proxy=off localhost:4000/api/v1/streaming/health || exit 1"
            ];
            depends_on = [ "db" "redis" ];
            networks = [ "internal_network" ];
          };
          sidekiq.service = {
            image = cfg.images.mastodon;
            restart = "always";
            volumes =
              [ "${cfg.state-directory}/mastodon:/mastodon/public/system" ];
            command = "bundle exec sidekiq";
            healthcheck.test =
              [ "CMD-SHELL" "ps aux | grep '[s]idekiq 6' || false" ];
            depends_on = [ "db" "redis" ];
            networks = [ "internal_network" "external_network" ];
            user = mkUserMap cfg.uids.mastodon;
          };
        };
      };
    in { imports = [ image ]; };
  };
}
