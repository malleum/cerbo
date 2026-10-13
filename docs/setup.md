# Setting up cerbo

This guide assumes NixOS with flakes. You'll set up two kinds of machine:

- **the server**: one machine with a GPU, which runs the model
- **clients**: every other machine, which runs `cerbo` and reaches the server
  over ssh

If you only have one machine, do step 2 and stop there: the server already
has the `cerbo` command.

Each step ends with a check. Don't move on until it passes; the
[troubleshooting](troubleshooting.md) page is organised by those checks.

## 1. Add the flake input

On every machine's config (or once, if they share a flake):

```nix
# flake.nix
inputs.cerbo = {
  url = "github:malleum/cerbo";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Pass `inputs` through to your modules (`specialArgs = { inherit inputs; };`)
if you don't already.

Your nixpkgs needs the `services.llama-swap` module (nixos-unstable, or 25.11
and later).

## 2. The server (the machine with the GPU)

```nix
{inputs, ...}: {
  imports = [inputs.cerbo.nixosModules.default];
  services.cerbo.enable = true;
}
```

That runs Qwen3.5-9B through Vulkan, which works on AMD, Intel and NVIDIA GPUs
with 8 GB of VRAM or more. Adjust for your hardware:

| Hardware | Add to `services.cerbo` |
| :--- | :--- |
| 8 GB+ GPU | nothing |
| 6 GB GPU or an iGPU | `model = "qwen3.5-4b";` |
| No usable GPU | `model = "qwen3.5-4b"; acceleration = "cpu";` (slow, but works) |
| A dGPU *and* an iGPU (most AMD desktops) | `vulkanDevice = "<vendor>:<device>";`, see below |
| Already use ROCm / CUDA | `acceleration = "rocm";` or `"cuda"` (the vendor stack must already work) |
| You game on that GPU | `ttl = 120;` so it unloads 2 minutes after the last use |

**Finding `vulkanDevice`:** without it, llama.cpp can pick the iGPU. List the
GPUs with their ids:

```console
$ nix run nixpkgs#pciutils -- -nn | grep -iE 'vga|3d|display'
03:00.0 VGA compatible controller [0300]: ... Navi 32 [Radeon RX 7700 XT / 7800 XT] [1002:747e]
0f:00.0 VGA compatible controller [0300]: ... Raphael [1002:164e]
```

The last bracket is the id. Use the discrete card's, here
`vulkanDevice = "1002:747e";`.

**Rebuild.** The first build downloads the model (6.7 GB, or 3.3 GB for the
4B) and, for Vulkan, compiles llama.cpp. Expect a few minutes.

**Check:**

```sh
systemctl status llama-swap          # active (running)
cerbo how much free space is on /    # first call takes a few extra seconds to load the model
```

## 3. Clients

### 3a. Make sure ssh works without prompts

The tunnel runs as a background service, so ssh can't ask for a password, a
passphrase or "are you sure you want to continue connecting". From the
client, as the user who will run `cerbo`:

```sh
ssh -o BatchMode=yes <host> true && echo ok
```

`<host>` is however you normally reach the server: `me@desktop`, a Tailscale
name, an alias from `~/.ssh/config`. If that prints `ok`, skip to 3b.
Otherwise:

- **Permission denied (publickey):** the server needs your client's public key
  in `users.users.<you>.openssh.authorizedKeys.keys`. The key must have no
  passphrase, or be loaded in an agent the systemd user manager can see (see
  [troubleshooting](troubleshooting.md#the-tunnel-keeps-restarting)).
- **Host key verification failed:** the client has never seen the server's host
  key. Run `ssh <host>` once by hand and answer yes, or better, pin it in the
  client's NixOS config:

  ```nix
  # the line from `cat /etc/ssh/ssh_host_ed25519_key.pub` on the server
  programs.ssh.knownHosts.desktop = {
    hostNames = ["desktop" "desktop.lan"]; # every name you use in tunnel.host
    publicKey = "ssh-ed25519 AAAA...";
  };
  ```

### 3b. Enable the client

```nix
{inputs, ...}: {
  imports = [inputs.cerbo.nixosModules.default];
  programs.cerbo = {
    enable = true;
    tunnel.host = "me@desktop";
  };
}
```

Any way you can ssh to the server works:

```nix
# A different port or key
tunnel.host = "me@desktop.lan";
tunnel.sshArgs = ["-p" "2222" "-i" "/home/me/.ssh/cerbo"];

# Through a jump host / relay (the server is behind NAT)
tunnel.host = "me@desktop";
tunnel.sshArgs = ["-J" "me@relay.example.com"];

# Tailscale
tunnel.host = "me@desktop"; # the machine's tailnet name

# An alias from ~/.ssh/config (HostName, Port, ProxyJump, IdentityFile all apply)
tunnel.host = "desktop";
```

The jump host also has to pass the check in 3a: its host key must be known
and your key accepted, without prompts.

If something else on the client already uses port 8091, set
`tunnel.localPort` to a free one; `cerbo` follows it automatically (log out
and back in once so the new `CERBO_URL` is picked up).

**Rebuild, then check:**

```sh
systemctl --user status cerbo-tunnel   # active (running)
cerbo how much free space is on /
```

**With home-manager instead of NixOS:** import
`inputs.cerbo.homeManagerModules.default` into your home-manager config and
set the same `programs.cerbo` options there. That works on any Linux with
home-manager and Nix, not only NixOS.

## 4. Hints (optional, but worth it)

cerbo already knows the common tools on each machine. Tell it what it can't
guess:

```nix
programs.cerbo.hints = ''
  - Repos are in ~/src/<name>; the NixOS config is ~/nixos.
  - The TV is HDMI-A-1. Its audio sink has "HDMI" in the name.
  - "The server" means my VPS, reachable as `ssh vps`.
'';
```

If it keeps getting something wrong, that's usually a missing hint. Run with
`-v` to see what it tried.

## Using another model server

Already running Ollama, LM Studio or vLLM? Skip `services.cerbo` and point the
client at it:

```nix
programs.cerbo = {
  enable = true;
  url = "http://127.0.0.1:11434/v1"; # Ollama's OpenAI-compatible endpoint
  model = "qwen3.5:9b";              # must support tool calling
};
```

`cerbo off` only works with the bundled llama-swap server.
