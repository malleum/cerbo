# cerbo

Ask a local model to do something in the shell.

```console
$ cerbo what is my default audio output and what volume is it at
$ wpctl status
Your default audio output is USB Audio Speakers at 50% volume.
```

The model gets one tool, `run_shell`, and up to ten turns to look around and
act. Every command is printed before it runs. Read-only commands from a short
allowlist (`ls`, `jq`, `df`, `wpctl status`, ...) run straight away. Anything
else waits for `[Y/n/q]`. At the end it prints a one-line summary, plus the
commands that changed something.

```
cerbo [-y] [-v] <task...>
  -y  run every command without asking
  -v  show command output
```

## Pieces

- **`cerbo.py`**: the CLI. Python standard library only, so it starts fast.
- **`nixosModules.default`**: `services.cerbo` runs [llama-swap] on loopback
  in front of llama.cpp (Vulkan). The model loads on the first request and
  unloads after `ttl` idle seconds, so the VRAM goes back to everything else.
  The default model is Qwen3.5-9B (UD-Q5_K_XL, 6.7 GB), fetched at build
  time.
- **`homeManagerModules.default`**: `programs.cerbo` installs the command
  and writes `~/.config/cerbo/hints.md`, which holds machine facts appended to
  the system prompt.

[llama-swap]: https://github.com/mostlygeek/llama-swap

## Use

```nix
# flake inputs
cerbo = {
  url = "github:malleum/cerbo";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

```nix
# NixOS
imports = [inputs.cerbo.nixosModules.default];
services.cerbo = {
  enable = true;
  vulkanDevice = "1002:747e"; # pin to the dGPU, hide the iGPU
};

# home-manager
imports = [inputs.cerbo.homeManagerModules.default];
programs.cerbo = {
  enable = true;
  hints = ''
    - Displays (jay): `jay randr show` lists connectors with product name,
      `physical size: W mm x H mm`, and disconnected/disabled state.
      Enable one with `jay randr output <CONNECTOR> enable`.
    - Audio is PipeWire. `wpctl status` lists sinks by id (`*` = default);
      `wpctl set-default <id>` changes it. pactl needs `-f json` before the
      subcommand for JSON output.
  '';
};
```

The hints matter. A 9B model will not guess how your compositor or audio
stack is queried. Without hints it tends to wander until it hits the step
limit; with them it usually gets there in three or four commands. If it keeps
getting something wrong, add a line.

## Options

| Option | Default | |
| :--- | :--- | :--- |
| `services.cerbo.port` | `8091` | loopback port |
| `services.cerbo.model` | Qwen3.5-9B UD-Q5_K_XL | any GGUF with tool calling |
| `services.cerbo.llamaCpp` | llama-cpp with Vulkan | swap for a ROCm/CUDA build |
| `services.cerbo.contextSize` | `16384` | |
| `services.cerbo.ttl` | `600` | idle seconds before unload, `0` = never |
| `services.cerbo.vulkanDevice` | `null` | `vendor:device` PCI id to run on |
| `services.cerbo.extraArgs` | `[]` | extra llama-server flags |
| `programs.cerbo.url` | `null` | endpoint, e.g. `http://desktop:8091/v1` |
| `programs.cerbo.hints` | `""` | appended to the system prompt |

`CERBO_URL` and `CERBO_MODEL` override the endpoint and model name at runtime.

## Develop

```sh
direnv allow                # or nix develop
python3 cerbo.py -v how much free space is on /
nix fmt . && flake8 --ignore E501,E731,W503 cerbo.py
```
