{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.cerbo;
  client = import ./client.nix {inherit lib pkgs;};
in {
  options.programs.cerbo = client.options;

  config = lib.mkIf cfg.enable {
    home.packages = [cfg.package];
    home.sessionVariables = client.env cfg;
    xdg.configFile."cerbo/hints.md" = lib.mkIf (cfg.hints != "") {text = cfg.hints;};

    systemd.user.services.cerbo-tunnel = lib.mkIf (cfg.tunnel.host != null) {
      Unit = {
        Description = client.tunnelDescription cfg;
        # Retry forever: the server is often asleep or off, and should be
        # usable the moment it is back.
        StartLimitIntervalSec = 0;
      };
      Service = {
        ExecStart = client.tunnelExec cfg;
        Restart = "always";
        RestartSec = 30;
      };
      Install.WantedBy = ["default.target"];
    };
  };
}
