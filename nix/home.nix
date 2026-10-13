{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.cerbo;
  inherit (lib) mkOption mkEnableOption types;

  tunnel = cfg.tunnel.host != null;
  url =
    if cfg.url != null
    then cfg.url
    else if tunnel && cfg.tunnel.localPort != 8091
    then "http://127.0.0.1:${toString cfg.tunnel.localPort}/v1"
    else null;
in {
  options.programs.cerbo = {
    enable = mkEnableOption "cerbo, the shell helper";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./package.nix {};
      defaultText = lib.literalMD "cerbo built from this flake";
      description = "The cerbo package.";
    };

    url = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "http://desktop:8091/v1";
      description = ''
        OpenAI-compatible endpoint to talk to. null keeps the built-in default,
        http://127.0.0.1:8091/v1, which is where the NixOS module serves.
      '';
    };

    tunnel = {
      host = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "desktop";
        description = ''
          SSH destination of a machine running services.cerbo. When set, a user
          service holds `ssh -L localPort:127.0.0.1:remotePort <host>` open, so
          cerbo runs commands here while the model runs there. Whatever
          ~/.ssh/config says about the host (ProxyJump, keys) applies; it must
          work non-interactively.
        '';
      };

      localPort = mkOption {
        type = types.port;
        default = 8091;
        description = "Local end of the tunnel.";
      };

      remotePort = mkOption {
        type = types.port;
        default = 8091;
        description = "services.cerbo.port on the remote host.";
      };

      sshArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["-o" "ProxyJump=none"];
        description = "Extra ssh arguments, placed before the host.";
      };
    };

    hints = mkOption {
      type = types.lines;
      default = "";
      example = ''
        - Displays: `jay randr show` lists connectors with `physical size`.
        - Audio is PipeWire; `wpctl set-default <id>` changes the output.
      '';
      description = ''
        Facts about this machine, appended to the system prompt on every call.
        A small model will not guess how your compositor or audio setup is
        queried; one line here saves it several wrong commands.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [cfg.package];
    home.sessionVariables = lib.mkIf (url != null) {CERBO_URL = url;};
    xdg.configFile."cerbo/hints.md" = lib.mkIf (cfg.hints != "") {text = cfg.hints;};

    systemd.user.services.cerbo-tunnel = lib.mkIf tunnel {
      Unit = {
        Description = "SSH tunnel to the cerbo model server on ${cfg.tunnel.host}";
        # Retry forever: the server is often asleep or off, and should be
        # usable the moment it is back.
        StartLimitIntervalSec = 0;
      };
      Service = {
        # No ControlMaster: a multiplexed master would outlive this unit and
        # keep the forward after systemd thinks it stopped it. BatchMode so a
        # missing key or host key fails here instead of hanging on a prompt.
        ExecStart = "${pkgs.openssh}/bin/ssh ${lib.escapeShellArgs ([
            "-N"
            "-o"
            "BatchMode=yes"
            "-o"
            "ExitOnForwardFailure=yes"
            "-o"
            "ControlMaster=no"
            "-o"
            "ControlPath=none"
            "-o"
            "ServerAliveInterval=15"
            "-o"
            "ServerAliveCountMax=3"
            "-L"
            "127.0.0.1:${toString cfg.tunnel.localPort}:127.0.0.1:${toString cfg.tunnel.remotePort}"
          ]
          ++ cfg.tunnel.sshArgs
          ++ [cfg.tunnel.host])}";
        Restart = "always";
        RestartSec = 30;
      };
      Install.WantedBy = ["default.target"];
    };
  };
}
