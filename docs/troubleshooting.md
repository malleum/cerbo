# Troubleshooting

Start with the check that fails, on the machine where it fails.

## `cerbo: model unreachable at http://127.0.0.1:8091/v1`

Nothing is answering on the client's end of the tunnel.

**On the server:**

```sh
systemctl status llama-swap
curl -s 127.0.0.1:8091/running    # {"running":[...]} means the server is fine
```

If `llama-swap` isn't running, `journalctl -u llama-swap -e` says why.

**On a client:**

```sh
systemctl --user status cerbo-tunnel
journalctl --user -u cerbo-tunnel -e
curl -s 127.0.0.1:8091/running
```

If the server works but this `curl` fails, the problem is the tunnel; see
below. If the server is off or asleep, the tunnel retries every 30 s and
cerbo works again shortly after it's back.

## The tunnel keeps restarting

`journalctl --user -u cerbo-tunnel -e` shows the ssh error:

| Error | Fix |
| :--- | :--- |
| `Host key verification failed` | Pin the server's key with `programs.ssh.knownHosts` (see [setup 3a](setup.md#3a-make-sure-ssh-works-without-prompts)), or `ssh <host>` once by hand. With a jump host, its key too. |
| `Permission denied (publickey)` | The server doesn't accept this client's key, or the key needs a passphrase. |
| `bind [127.0.0.1]:8091: Address already in use` | Something on the client already uses the port. Set `programs.cerbo.tunnel.localPort` to another one. |
| `Could not resolve hostname` | Use a name the client can resolve, or an IP, or an alias from `~/.ssh/config`. |
| `connect to host ... Connection refused` / timed out | The server is off, or sshd isn't reachable from here. |

**Keys with a passphrase:** the tunnel can't type it. Either use a separate
passphrase-less key for the tunnel (`tunnel.sshArgs = ["-i" "/home/me/.ssh/cerbo"];`
and add its `.pub` to the server), or make sure your ssh agent is visible to
systemd user services:

```sh
systemctl --user show-environment | grep SSH_AUTH_SOCK
```

If that prints nothing, the agent isn't visible and the passphrase-less key
is the simpler route.

## The first call is slow

That's the model loading into VRAM: a few seconds from page cache, longer
right after boot. Later calls answer in under a second until `ttl` seconds of
idle time unload it again. Raise `services.cerbo.ttl` (or set `0`) to keep it
loaded.

## Every call is slow

- **It's running on the iGPU or the CPU.** Run `nix run nixpkgs#nvtopPackages.full`
  on the server while a `cerbo` command runs and see which GPU's memory and
  load go up. If it's the wrong one, set `services.cerbo.vulkanDevice` to the
  discrete card (see [setup](setup.md#2-the-server-the-machine-with-the-gpu)).
- **The model doesn't fit in VRAM.** Use `model = "qwen3.5-4b";`, or close
  whatever else is using the GPU. `cerbo off` frees cerbo's share.
- **`reasoning = true`** makes the model think before every command. That's
  about three times slower.

## It runs the wrong commands

- Run with `-v` to see each command's output and where it went wrong.
- Add a hint (`programs.cerbo.hints`) for whatever it guessed wrong, such as
  where things live or which device is which.
- Ask for one thing at a time. A 9B model handles "do X" far better than "do
  X, then Y, then Z".
- The 4B preset is fine for one or two steps but gets lost sooner. Use the
  9B if the GPU has room.

## A game stutters or picks low textures

The model holds about 7 GB of VRAM while loaded. Run `cerbo off` before
starting the game, or set `services.cerbo.ttl = 120;` so it unloads soon after
you stop using it.

## Still stuck

Check the raw API from the client:

```sh
curl -s 127.0.0.1:8091/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"cerbo","messages":[{"role":"user","content":"say hi"}]}' | jq .
```

If that answers, the server and tunnel are fine and the problem is in cerbo
itself. Open an issue with the output of `cerbo -v <your task>`.
