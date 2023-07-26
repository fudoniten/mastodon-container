{ config, lib, pkgs, ... }@toplevel:

with lib;
let cfg = config.services.mastodonContainer;

in {
  options.services.mastodonContainer = {
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
    };

    state-directory = mkOption {
      type = str;
      description = "Port at which to store server data.";
    };

    ports = {
      web = mkOption {
        type = port;
        description = "Port at which to serve Mastodon web requests.";
        default = 3000;
      };
      streaming = mkOption {
        type = port;
        description = "Port at which to serve Mastodon streaming requests.";
        default = 4000;
      };
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

    virtualisation.arion.projects.mastodon.settings = let
      mkUserMap = uid: "${toString uid}:${toString uid}";
      image = { pkgs, ... }: {
        project.name = "mastodon";
        networks = {
          internal_network.internal = true;
          external_network.internal = false;
        };
        services = {
          postgres.service = {
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
            # TODO: bulid image?
            image = cfg.images.mastodon;
            restart = "always";
            volumes =
              [ "${cfg.state-directory}/mastodon:/mastodon/public/system" ];
            command = ''
              bash -c "rm -f /mastodon/tmp/pids/server.pid; bundle exec rails s -p 3000"'';
            healthcheck.test = [
              "CMD-SHELL"
              "wget -q --spider --proxy=off localhost:3000/health || exit 1"
            ];
            ports = [ "${toString cfg.ports.web}:3000" ];
            depends_on = [ "postgres" "redis" ];
            networks = [ "internal_network" "external_network" ];
            user = mkUserMap cfg.uids.mastodon;
          };
          streaming.service = {
            image = cfg.images.mastodon;
            restart = "always";
            command = "node ./streaming";
            healthcheck.test = [
              "CMD-SHELL"
              "wget -q --spider --proxy=off localhost:4000/api/v1/streaming/health || exit 1"
            ];
            ports = [ "${toString cfg.ports.streaming}:4000" ];
            depends_on = [ "postgres" "redis" ];
            networks = [ "internal_network" "external_network" ];
          };
          sidekiq.service = {
            image = cfg.images.mastodon;
            restart = "always";
            volumes =
              [ "${cfg.state-directory}/mastodon:/mastodon/public/system" ];
            command = "bundle exec sidekiq";
            healthcheck.test =
              [ "CMD-SHELL" "ps aux | grep '[s]idekiq 6' || false" ];
            depends_on = [ "postgres" "redis" ];
            networks = [ "internal_network" "external_network" ];
            user = mkUserMap cfg.uids.mastodon;
          };
        };
      };
    in { imports = [ image ]; };
  };
}
