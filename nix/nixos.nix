# services.cerbo: llama-swap serving one model named "cerbo". llama-swap
# starts llama-server on the first request and stops it after `ttl` idle
# seconds, so the VRAM it holds goes back to everything else without anyone
# remembering. A cold call pays a few seconds to load the model from page cache.
#
# programs.cerbo: the command itself, for NixOS users without home-manager
# (home-manager users can use homeManagerModules.default instead, or as well).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.cerbo;
  clientCfg = config.programs.cerbo;
  client = import ./client.nix {inherit lib pkgs;};
  inherit (lib) mkOption mkEnableOption types;

  # Pinned to a commit so the hash cannot drift. Fetched at build time rather
  # than by llama-server's -hf on first use: a multi-GB download inside the
  # first `cerbo` call would blow through every timeout. UD-Q5_K_XL over Q4:
  # at this size the extra precision is nearly free, and tool-call formatting
  # is where low quants slip first.
  presets = {
    "qwen3.5-9b" = pkgs.fetchurl {
      url = "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/3885219b6810b007914f3a7950a8d1b469d598a5/Qwen3.5-9B-UD-Q5_K_XL.gguf";
      sha256 = "96cf42ddb97f9572410a72b9ed6f2299b1e887ee08da4c2a6c01e897cfa9f673";
    };
    "qwen3.5-4b" = pkgs.fetchurl {
      url = "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-UD-Q5_K_XL.gguf";
      sha256 = "b4c36a8e14a80c21bcab5a067ce342b2e70e28f60b4aa95ad12203fa17b87426";
    };
  };

  # isString first: indexing presets with a path-typed value would copy the
  # file into the store just to look it up.
  modelFile =
    if builtins.isString cfg.model && presets ? ${cfg.model}
    then presets.${cfg.model}
    else cfg.model;

  llamaCppFor = {
    vulkan = pkgs.llama-cpp.override {vulkanSupport = true;};
    rocm = pkgs.llama-cpp.override {rocmSupport = true;};
    cuda = pkgs.llama-cpp.override {cudaSupport = true;};
    cpu = pkgs.llama-cpp;
  };
in {
  options.services.cerbo = {
    enable = mkEnableOption "the cerbo model server (llama-swap + llama.cpp)";

    port = mkOption {
      type = types.port;
      default = 8091;
      description = ''
        Loopback port llama-swap listens on. It is never exposed: the API has no
        authentication, so other machines reach it through programs.cerbo.tunnel.
      '';
    };

    acceleration = mkOption {
      type = types.enum ["vulkan" "rocm" "cuda" "cpu"];
      default = "vulkan";
      description = ''
        Which llama.cpp build to run. Vulkan works on AMD, Intel and NVIDIA
        with no extra setup and is close to native speed for a model this
        size. rocm/cuda need the vendor stack configured on the host (cuda is
        unfree); cpu works anywhere, best with model = "qwen3.5-4b".
        Ignored when `llamaCpp` is set.
      '';
    };

    llamaCpp = mkOption {
      type = types.package;
      default = llamaCppFor.${cfg.acceleration};
      defaultText = lib.literalMD "llama-cpp built for `acceleration`";
      description = "llama.cpp build providing llama-server.";
    };

    model = mkOption {
      type = types.either (types.enum (lib.attrNames presets)) types.path;
      default = "qwen3.5-9b";
      example = lib.literalExpression ''"qwen3.5-4b" or ./models/my-model.gguf'';
      description = ''
        A preset or a GGUF file. The model needs tool calling.
        - qwen3.5-9b (6.7 GB): the default, for GPUs with 8 GB of VRAM or more.
        - qwen3.5-4b (3.3 GB): 6 GB cards, iGPUs and CPU-only machines.
          Noticeably worse at multi-step tasks.
        Larger models (Qwen3 30B-A3B, gpt-oss-20b, ...) work as a path or a
        fetchurl, but may need `extraArgs` for partial offload.
      '';
    };

    contextSize = mkOption {
      type = types.ints.positive;
      default = 16384;
      description = "Context length passed to llama-server (-c).";
    };

    reasoning = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Let the model think before answering. Better choices on hard tasks,
        at roughly three times the wait before each command.
      '';
    };

    ttl = mkOption {
      type = types.ints.unsigned;
      default = 600;
      description = ''
        Seconds of idle time before the model is unloaded. 0 keeps it loaded.
        `cerbo off` unloads it at once.
      '';
    };

    vulkanDevice = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "1002:747e";
      description = ''
        PCI vendor:device id of the GPU to run on with Vulkan. Mesa's
        device-select layer then hides every other GPU from llama-server,
        which keeps it off an iGPU whatever order the render nodes come up in.
        Find it with `llama-server --list-devices` or
        /sys/class/drm/card*/device/{vendor,device}.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = {HSA_OVERRIDE_GFX_VERSION = "11.0.0";};
      description = "Extra environment for llama-server (e.g. ROCm overrides).";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["--n-cpu-moe" "24"];
      description = "Extra arguments for llama-server.";
    };
  };

  options.programs.cerbo = client.options;

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # The machine with the model usually wants the command too.
      programs.cerbo.enable = lib.mkDefault true;

      services.llama-swap = {
        enable = true;
        listenAddress = "127.0.0.1";
        inherit (cfg) port;
        settings = {
          healthCheckTimeout = 120;
          models.cerbo = {
            cmd = lib.escapeShellArgs ([
                (lib.getExe' cfg.llamaCpp "llama-server")
                "--port"
                "\${PORT}"
                "-m"
                "${modelFile}"
                "-ngl"
                "99"
                "-c"
                (toString cfg.contextSize)
                "--reasoning"
                (
                  if cfg.reasoning
                  then "on"
                  else "off"
                )
                "--no-webui"
              ]
              ++ cfg.extraArgs);
            inherit (cfg) ttl;
            env =
              lib.mapAttrsToList (k: v: "${k}=${v}") cfg.environment
              ++ lib.optionals (cfg.vulkanDevice != null) [
                "MESA_VK_DEVICE_SELECT=${cfg.vulkanDevice}"
                "MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE=1"
              ];
          };
        };
      };

      # The upstream unit is hardened for CPU and Vulkan, which is what has
      # been tested. ROCm and CUDA load GPU code at runtime and need /dev/kfd
      # and the render group; loosen just what they are known to need.
      systemd.services.llama-swap.serviceConfig = lib.mkIf (lib.elem cfg.acceleration ["rocm" "cuda"]) {
        MemoryDenyWriteExecute = lib.mkForce false;
        SupplementaryGroups = ["render" "video"];
      };
    })

    (lib.mkIf clientCfg.enable {
      environment.systemPackages = [clientCfg.package];
      environment.sessionVariables = client.env clientCfg;
      environment.etc."cerbo/hints.md" = lib.mkIf (clientCfg.hints != "") {text = clientCfg.hints;};

      systemd.user.services.cerbo-tunnel = lib.mkIf (clientCfg.tunnel.host != null) {
        description = client.tunnelDescription clientCfg;
        wantedBy = ["default.target"];
        # Retry forever: the server is often asleep or off, and should be
        # usable the moment it is back.
        startLimitIntervalSec = 0;
        serviceConfig = {
          ExecStart = client.tunnelExec clientCfg;
          Restart = "always";
          RestartSec = 30;
        };
      };
    })
  ];
}
