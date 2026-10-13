# The cerbo command's options, shared by the NixOS module (programs.cerbo)
# and the home-manager module. Each side wires them up its own way: system
# packages and /etc vs home.packages and ~/.config, and the tunnel as a
# systemd user unit in either syntax.
{
  lib,
  pkgs,
}: let
  inherit (lib) mkOption mkEnableOption types;
in {
  options = {
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
      example = "http://127.0.0.1:11434/v1";
      description = ''
        OpenAI-compatible endpoint to talk to. null means http://127.0.0.1:8091/v1
        (where services.cerbo serves), or the local end of the tunnel when
        tunnel.host is set. Any OpenAI-compatible server works, e.g. Ollama at
        http://127.0.0.1:11434/v1 together with `model`.
      '';
    };

    model = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "qwen3.5:9b";
      description = ''
        Model name sent with each request. null means "cerbo", the name
        services.cerbo serves under. Set it when pointing `url` at another
        server (Ollama, LM Studio, vLLM). The model needs tool calling.
      '';
    };

    hints = mkOption {
      type = types.lines;
      default = "";
      example = ''
        - Repos live in ~/src/<name>.
        - The TV is HDMI-A-1; its audio sink is the one with "HDMI" in the name.
      '';
      description = ''
        Facts about this machine, appended to the system prompt on every call.
        Common tools (PipeWire, NetworkManager, systemd, git, nix, the running
        compositor) already have built-in recipes; put here what a small model
        could not guess: where things live, which device is which.
      '';
    };

    tunnel = {
      host = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "me@desktop.lan";
        description = ''
          SSH destination of a machine running services.cerbo. When set, a
          systemd user service holds `ssh -L localPort:127.0.0.1:remotePort <host>`
          open, so cerbo runs commands here while the model runs there. Plain
          `user@host`, a ~/.ssh/config alias (with ProxyJump, keys, ...) and
          Tailscale names all work; it must connect without prompts.
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
        example = ["-i" "/home/me/.ssh/id_ed25519" "-p" "2222"];
        description = "Extra ssh arguments, placed before the host.";
      };
    };
  };

  # The environment cerbo should see, given the options.
  env = cfg:
    lib.filterAttrs (_: v: v != null) {
      CERBO_URL =
        if cfg.url != null
        then cfg.url
        else if cfg.tunnel.host != null && cfg.tunnel.localPort != 8091
        then "http://127.0.0.1:${toString cfg.tunnel.localPort}/v1"
        else null;
      CERBO_MODEL = cfg.model;
    };

  tunnelDescription = cfg: "SSH tunnel to the cerbo model server on ${cfg.tunnel.host}";

  # No ControlMaster: a multiplexed master would outlive the unit and keep the
  # forward after systemd thinks it stopped it. BatchMode so a missing key or
  # host key fails in the journal instead of hanging on a prompt.
  tunnelExec = cfg: "${pkgs.openssh}/bin/ssh ${lib.escapeShellArgs ([
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
}
