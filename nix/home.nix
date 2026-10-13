{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.cerbo;
  inherit (lib) mkOption mkEnableOption types;
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
    home.sessionVariables = lib.mkIf (cfg.url != null) {CERBO_URL = cfg.url;};
    xdg.configFile."cerbo/hints.md" = lib.mkIf (cfg.hints != "") {text = cfg.hints;};
  };
}
