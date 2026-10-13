# llama-swap on loopback, serving one model named "cerbo". llama-swap starts
# llama-server on the first request and stops it after `ttl` idle seconds, so
# the VRAM it holds goes back to everything else without anyone remembering.
# A cold call pays a few seconds to load the model from page cache.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.cerbo;
  inherit (lib) mkOption mkEnableOption types;
in {
  options.services.cerbo = {
    enable = mkEnableOption "the cerbo model server (llama-swap + llama.cpp)";

    port = mkOption {
      type = types.port;
      default = 8091;
      description = "Loopback port llama-swap listens on.";
    };

    model = mkOption {
      type = types.path;
      # Pinned to a commit so the hash cannot drift. Fetched at build time
      # rather than by llama-server's -hf on first use: a multi-GB download
      # inside the first `cerbo` call would blow through every timeout.
      # UD-Q5_K_XL over Q4: at 9B the extra precision is nearly free, and
      # tool-call formatting is where low quants slip first.
      default = pkgs.fetchurl {
        url = "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/3885219b6810b007914f3a7950a8d1b469d598a5/Qwen3.5-9B-UD-Q5_K_XL.gguf";
        sha256 = "96cf42ddb97f9572410a72b9ed6f2299b1e887ee08da4c2a6c01e897cfa9f673";
      };
      defaultText = lib.literalMD "Qwen3.5-9B, UD-Q5_K_XL GGUF";
      description = "GGUF file to serve. Needs a model with tool calling.";
    };

    llamaCpp = mkOption {
      type = types.package;
      # Vulkan rather than ROCm/CUDA: works on any GPU with a Vulkan driver
      # and is close enough in speed for a model this size.
      default = pkgs.llama-cpp.override {vulkanSupport = true;};
      defaultText = lib.literalExpression "pkgs.llama-cpp.override { vulkanSupport = true; }";
      description = "llama.cpp build providing llama-server.";
    };

    contextSize = mkOption {
      type = types.ints.positive;
      default = 16384;
      description = "Context length passed to llama-server (-c).";
    };

    ttl = mkOption {
      type = types.ints.unsigned;
      default = 600;
      description = "Seconds of idle time before the model is unloaded. 0 keeps it loaded.";
    };

    vulkanDevice = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "1002:747e";
      description = ''
        PCI vendor:device id of the GPU to run on. Mesa's device-select layer
        then hides every other GPU from llama-server, which keeps it off an
        iGPU whatever order the render nodes come up in. Find it with
        `llama-server --list-devices` or /sys/class/drm/card*/device/{vendor,device}.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["--temp" "0.3"];
      description = "Extra arguments for llama-server.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.llama-swap = {
      enable = true;
      listenAddress = "127.0.0.1";
      inherit (cfg) port;
      settings = {
        healthCheckTimeout = 60;
        models.cerbo = {
          cmd = lib.escapeShellArgs ([
              (lib.getExe' cfg.llamaCpp "llama-server")
              "--port"
              "\${PORT}"
              "-m"
              "${cfg.model}"
              "-ngl"
              "99"
              "-c"
              (toString cfg.contextSize)
              # Thinking roughly triples the time to the first command and did
              # not pick better ones in testing.
              "--reasoning"
              "off"
              "--no-webui"
            ]
            ++ cfg.extraArgs);
          inherit (cfg) ttl;
          env = lib.optionals (cfg.vulkanDevice != null) [
            "MESA_VK_DEVICE_SELECT=${cfg.vulkanDevice}"
            "MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE=1"
          ];
        };
      };
    };
  };
}
