# NixOS module for running Jesse as a systemd service.
#
# Jesse reads ALL runtime config from a `.env` file in its project directory
# (jesse/services/env.py uses dotenv_values, not the process environment), so
# this module renders that file in preStart. Secrets come in via systemd
# LoadCredential and never enter the nix store.
{ config, lib, ... }:
let
  cfg = config.services.jesse;

  # When postgres.local, we use peer auth over the unix socket: the system
  # user "jesse" maps to the db user "jesse", no password involved.
  pgHost = if cfg.postgres.local then "/run/postgresql" else cfg.postgres.host;
  pgPort = if cfg.postgres.local then config.services.postgresql.settings.port else cfg.postgres.port;
  pgName = if cfg.postgres.local then "jesse" else cfg.postgres.name;
  pgUser = if cfg.postgres.local then "jesse" else cfg.postgres.user;
  redisHost = if cfg.redis.local then "127.0.0.1" else cfg.redis.host;
  redisPort = if cfg.redis.local then config.services.redis.servers.jesse.port else cfg.redis.port;
in
{
  options.services.jesse = {
    enable = lib.mkEnableOption "Jesse trading framework";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Jesse environment to run (set by the flake's nixosModule).";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the Jesse web app binds to. Set to 0.0.0.0 to expose directly (prefer a reverse proxy).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9000;
      description = "Port for the Jesse web app.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.path;
      description = "File containing the web-UI login password (PASSWORD in .env).";
    };

    postgres = {
      local = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Provision PostgreSQL on this host (unix socket, peer auth,
          database/user "jesse"). When false, the host/port/name/user/
          passwordFile options below point at an external server.
        '';
      };
      host = lib.mkOption { type = lib.types.str; default = "127.0.0.1"; description = "External PostgreSQL host."; };
      port = lib.mkOption { type = lib.types.port; default = 5432; description = "External PostgreSQL port."; };
      name = lib.mkOption { type = lib.types.str; default = "jesse"; description = "External database name."; };
      user = lib.mkOption { type = lib.types.str; default = "jesse"; description = "External database user."; };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "File containing the external database password.";
      };
    };

    redis = {
      local = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run a dedicated Redis instance on this host. When false, point at an external server below.";
      };
      host = lib.mkOption { type = lib.types.str; default = "127.0.0.1"; description = "External Redis host."; };
      port = lib.mkOption { type = lib.types.port; default = 6379; description = "Redis port (local or external)."; };
      db = lib.mkOption { type = lib.types.int; default = 0; description = "Redis database number."; };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "File containing the external Redis password.";
      };
    };

    strategiesDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/srv/jesse-strategies";
      description = ''
        Directory holding the strategies. Symlinked into the project dir as
        `strategies`. Must be readable by the `jesse` user; may be a nix
        store path (e.g. a flake input) for immutable deploys. When null, a
        plain writable directory is created at /var/lib/jesse/strategies.
      '';
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { POSTGRES_SSLMODE = "require"; };
      description = "Extra key=value pairs appended to the generated .env.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.postgres.local || cfg.postgres.passwordFile != null;
        message = "services.jesse: external PostgreSQL requires postgres.passwordFile.";
      }
    ];

    services.postgresql = lib.mkIf cfg.postgres.local {
      enable = true;
      ensureDatabases = [ "jesse" ];
      ensureUsers = [{ name = "jesse"; ensureDBOwnership = true; }];
    };

    services.redis.servers.jesse = lib.mkIf cfg.redis.local {
      enable = true;
      port = cfg.redis.port;
    };

    users.users.jesse = {
      isSystemUser = true;
      group = "jesse";
      home = "/var/lib/jesse";
    };
    users.groups.jesse = { };

    systemd.services.jesse = {
      description = "Jesse trading framework";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ]
        ++ lib.optional cfg.postgres.local "postgresql.service"
        ++ lib.optional cfg.redis.local "redis-jesse.service";
      requires = lib.optional cfg.postgres.local "postgresql.service"
        ++ lib.optional cfg.redis.local "redis-jesse.service";

      environment.HOME = "/var/lib/jesse";

      preStart = ''
        mkdir -p storage
        ${if cfg.strategiesDir != null then ''
          if [ -d strategies ] && [ ! -L strategies ]; then
            echo "refusing to replace real directory /var/lib/jesse/strategies with a symlink to ${cfg.strategiesDir}; move its contents first" >&2
            exit 1
          fi
          ln -sfn ${cfg.strategiesDir} strategies
        '' else "mkdir -p strategies"}
        umask 077
        {
          echo "PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/password")"
          echo "APP_HOST=${cfg.host}"
          echo "APP_PORT=${toString cfg.port}"
          echo "POSTGRES_HOST=${pgHost}"
          echo "POSTGRES_PORT=${toString pgPort}"
          echo "POSTGRES_NAME=${pgName}"
          echo "POSTGRES_USERNAME=${pgUser}"
          ${if cfg.postgres.passwordFile != null && !cfg.postgres.local
            then ''echo "POSTGRES_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/postgres-password")"''
            else ''echo "POSTGRES_PASSWORD="''}
          echo "REDIS_HOST=${redisHost}"
          echo "REDIS_PORT=${toString redisPort}"
          echo "REDIS_DB=${toString cfg.redis.db}"
          ${if cfg.redis.passwordFile != null && !cfg.redis.local
            then ''echo "REDIS_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/redis-password")"''
            else ''echo "REDIS_PASSWORD="''}
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: ''echo "${k}=${v}"'') cfg.extraEnv)}
        } > .env
      '';

      serviceConfig = {
        User = "jesse";
        Group = "jesse";
        StateDirectory = "jesse";
        WorkingDirectory = "/var/lib/jesse";
        ExecStart = "${cfg.package}/bin/jesse run";
        Restart = "on-failure";
        RestartSec = 5;
        LoadCredential = [ "password:${cfg.passwordFile}" ]
          ++ lib.optional (cfg.postgres.passwordFile != null && !cfg.postgres.local)
            "postgres-password:${cfg.postgres.passwordFile}"
          ++ lib.optional (cfg.redis.passwordFile != null && !cfg.redis.local)
            "redis-password:${cfg.redis.passwordFile}";
      };
    };
  };
}
