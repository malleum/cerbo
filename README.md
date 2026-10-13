# cerbo

Ask a local model to do something in the shell.

```console
$ cerbo what wifi am I on and what is my local ip
$ nmcli -t -f active,ssid dev wifi | grep '^yes'
$ ip -br addr
You are on HomeNet; your local IPv4 address is 192.168.1.42.

$ cerbo -t Mi ŝatas programi en la vespero
I like programming in the evening.
```

One machine with a GPU runs the model. Any number of machines run the
`cerbo` command and reach that model over ssh. Commands always run on the
machine where you typed `cerbo`; only the model calls travel.

**Setup:** [docs/setup.md](docs/setup.md) walks through it step by step, with
a check after each step. If something doesn't work, see
[docs/troubleshooting.md](docs/troubleshooting.md).

## Quick start (NixOS, flakes)

```nix
# flake.nix
inputs.cerbo = {
  url = "github:malleum/cerbo";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

On the machine with the GPU:

```nix
imports = [inputs.cerbo.nixosModules.default];
services.cerbo.enable = true; # model server + the cerbo command
```

On every other machine (anything you can `ssh` to the GPU machine from):

```nix
imports = [inputs.cerbo.nixosModules.default];
programs.cerbo = {
  enable = true;
  tunnel.host = "me@desktop"; # any ssh destination or ~/.ssh/config alias
};
```

Then try `cerbo how much free space is on /`.

Home-manager users can use `inputs.cerbo.homeManagerModules.default` for the
client instead; it has the same `programs.cerbo` options.

## Using it

```
cerbo                       prompt for the task (see below)
cerbo [-y] [-v] <task...>   do something
  -y                        run every command without asking
  -v                        show command output
cerbo -t <text>             translate to English (source language detected)
cerbo -T <lang> <text>      translate to <lang>
echo ... | cerbo -t         text from stdin works too
cerbo off                   unload the model now (e.g. before a game)
```

**Bare `cerbo` is usually the better way in.** It opens a `cerbo>` prompt
and loads the model while you type, so the answer starts as soon as you press
Enter. And since the text never goes through your shell, `?`, `*`, `'` and `"`
need no quoting (`cerbo what's this?` on the command line is a zsh glob
error). `cerbo -t` / `cerbo -T <lang>` with no text work the same way.

The model gets one tool, `run_shell`, and up to ten turns to look around and
act. Every command is printed before it runs:

- **Read-only commands run straight away.** That covers `ls`, `cat`, `grep`,
  `jq`, `df`, `ps`, `ss`, `wpctl status`, `nmcli`, `ip addr`, `systemctl
  status`, `journalctl`, `git status/diff/log/show`, `nix path-info`,
  `fastfetch`, `qalc` and similar. The full list is `READ_ONLY` in `cerbo.py`,
  and it's tested in `tests/test_allowlist.py`.
- **Everything else waits for `[Y/n/q, or type a reply]`.** Anything other
  than y/n/q goes to the model as your answer, e.g. "no, use trash instead"
  or "misclick, run it".
- **Declined or out of steps:** if a run ends on a command you declined, or
  on the step limit, a `>` prompt lets you keep going in the same
  conversation. Enter quits.

It's a 9B model, so read the yellow (unapproved) commands before pressing `y`.

Things it does well: "move all audio to my headphones", "which services failed
and why", "what's using port 8080", "which of my repos have uncommitted
changes", "what are the biggest paths in my system closure", "solve x^2 = 2x +
3", "how good are this machine's specs".

## How it fits together

```
 laptop                         ssh -L (cerbo-tunnel)           desktop with GPU
 cerbo ──HTTP──> 127.0.0.1:8091 ═══════════════════════> 127.0.0.1:8091 llama-swap
   └─ runs commands here                                     └─ llama-server + model
                                                                loads on first request,
                                                                unloads after `ttl`
```

- **`cerbo.py`** is the client. It uses only the Python standard library, so
  it starts fast. Its system prompt is built for the machine it runs on: OS,
  desktop session, which tools are installed, and recipes for only those tools
  (PipeWire, NetworkManager, systemd, git, nix, fastfetch, qalc, and the
  running compositor: jay, Hyprland, sway, niri, other wlroots, or X11).
- **`services.cerbo`** (NixOS) runs [llama-swap] in front of llama.cpp, on
  loopback only: the API has no authentication. The model is fetched at
  build time and pinned by hash.
- **`programs.cerbo`** (NixOS or home-manager) installs the command, writes
  your hints, and holds the ssh tunnel to the GPU machine.

[llama-swap]: https://github.com/mostlygeek/llama-swap

## Hints

Built-in recipes cover the common tools. What a small model cannot guess
about *your* machine goes in `hints`: where your repos live, which output is
the TV, quirks of your setup. One line here saves it several wrong commands.

```nix
programs.cerbo.hints = ''
  - Repos are in ~/src/<name>; the NixOS config is /etc/nixos.
  - The TV is HDMI-A-1; its audio sink has "HDMI" in the name.
'';
```

System hints (`/etc/cerbo/hints.md`) and user hints
(`~/.config/cerbo/hints.md`) are both read.

## Options

**`services.cerbo`** (NixOS, on the GPU machine)

| Option | Default | |
| :--- | :--- | :--- |
| `enable` | `false` | |
| `port` | `8091` | loopback only |
| `acceleration` | `"vulkan"` | `vulkan` (AMD, Intel, NVIDIA), `rocm`, `cuda` (unfree), `cpu` |
| `llamaCpp` | built for `acceleration` | any llama.cpp package |
| `model` | `"qwen3.5-9b"` | `"qwen3.5-4b"` for ≤6 GB GPUs or CPU, or a path to any GGUF with tool calling |
| `contextSize` | `16384` | |
| `reasoning` | `false` | think first: better on hard tasks, ~3x slower |
| `ttl` | `600` | idle seconds before unload, `0` = never |
| `vulkanDevice` | `null` | `vendor:device` PCI id, to keep it off an iGPU |
| `environment` | `{}` | extra env, e.g. `HSA_OVERRIDE_GFX_VERSION` |
| `extraArgs` | `[]` | extra llama-server flags (e.g. `--n-cpu-moe 24` for big MoE models) |

**`programs.cerbo`** (NixOS and home-manager, on every machine)

| Option | Default | |
| :--- | :--- | :--- |
| `enable` | `false` (on with `services.cerbo`) | |
| `tunnel.host` | `null` | ssh destination running `services.cerbo` |
| `tunnel.sshArgs` | `[]` | extra ssh arguments, e.g. `["-J" "me@relay"]` |
| `tunnel.localPort` | `8091` | local end of the tunnel |
| `tunnel.remotePort` | `8091` | the server's `services.cerbo.port` |
| `hints` | `""` | appended to the system prompt |
| `url` | `null` → `http://127.0.0.1:8091/v1` | another OpenAI-compatible server (Ollama, ...) |
| `model` | `null` → `"cerbo"` | model name on that server |

`CERBO_URL` and `CERBO_MODEL` override the endpoint and model at runtime.

## Develop

```sh
direnv allow                       # or nix develop
python3 cerbo.py -v how much free space is on /
python3 tests/test_allowlist.py    # also runs in `nix flake check`
nix fmt .
```

## License

MIT, see [LICENSE](LICENSE).
