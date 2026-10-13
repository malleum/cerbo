"""cerbo: ask the local model to do something in the shell.

    cerbo change my sound output to the display with the largest screen

The model gets one tool, run_shell, and a few turns to look around and act.
Every command is printed before it runs. Read-only commands from a short
allowlist run straight away; anything else waits for a y at the prompt, so a
9B model guessing wrong costs a keypress, not a file. -y skips the prompt.

Standard library only: this starts on every invocation, and pulling in an HTTP
client would cost more than the request it makes.
"""

import argparse
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

URL = os.environ.get("CERBO_URL", "http://127.0.0.1:8091/v1")
MODEL = os.environ.get("CERBO_MODEL", "cerbo")
HINTS = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "cerbo/hints.md"
MAX_STEPS = 10
MAX_OUTPUT = 4000

# Tools worth telling the model about if they are on PATH. Saves it a turn of
# `which` before it does anything useful.
KNOWN_TOOLS = [
    "wpctl", "pactl", "jay", "hyprctl", "jq", "nmcli", "bluetoothctl",
    "brightnessctl", "playerctl", "systemctl", "journalctl", "notify-send",
    "wl-copy", "rg", "fd", "nh",
]

# argv0 -> what counts as read-only: None for any arguments, a set of allowed
# first arguments, or a predicate on the whole argv. Deliberately absent:
# env/xargs/find/fd/awk/sed/uniq (each can run or write something given the
# right argument), curl, `nix eval`/`nix build` (both can fetch and build
# arbitrary things), and anything that takes a file to write.
READ_ONLY = {
    "ls": None, "cat": None, "head": None, "tail": None, "wc": None,
    "grep": None, "rg": None, "jq": None, "sort": None, "cut": None, "tr": None,
    "column": None, "echo": None, "printf": None, "which": None, "type": None,
    "uname": None, "hostname": None, "date": None, "id": None, "whoami": None,
    "ps": None, "pgrep": None, "lsblk": None, "df": None, "du": None,
    "free": None, "uptime": None, "realpath": None, "readlink": None,
    "stat": None, "file": None, "journalctl": None, "ss": None,
    "findmnt": None, "lspci": None, "lsusb": None, "lscpu": None, "nproc": None,
    "numfmt": None,
    "nixos-version": None,
    "ip": {"addr", "address", "a", "link", "l", "route", "r", "neigh", "-br",
           "-brief", "-j", "-json", "-4", "-6", "-c", "-color"},
    "nix": lambda argv: argv[1:2] in (["path-info"], ["why-depends"], ["--version"])
    or argv[1:3] == ["store", "diff-closures"],
    "nix-store": lambda argv: len(argv) > 1
    and (argv[1] == "--query" or re.fullmatch(r"-q[a-zA-Z]*", argv[1]) is not None),
    "nixos-rebuild": {"list-generations"},
    "wpctl": {"status", "inspect", "get-volume"},
    "pactl": {"list", "info", "get-default-sink", "get-default-source",
              "get-sink-volume", "get-sink-mute", "-f"},
    "jay": {"randr", "version", "clients", "tree"},
    "hyprctl": {"monitors", "workspaces", "clients", "devices", "activewindow", "-j"},
    "nmcli": {"device", "dev", "d", "connection", "con", "c", "general", "g",
              "-t", "-f", "-g", "--fields", "--get-values"},
    "bluetoothctl": {"devices", "info", "show", "list"},
    "systemctl": {"status", "is-active", "is-enabled", "is-failed", "list-units",
                  "list-unit-files", "list-timers", "show", "cat", "--failed", "--user"},
    "playerctl": {"status", "metadata", "-l", "--list-all"},
    "brightnessctl": {"get", "info", "-l"},
}

# Arguments that turn an allowed command into one that changes state, after
# the allowed subcommand check has passed (`pactl -f json set-default-sink`,
# `jay randr output DP-2 disable`, `systemctl --user stop`).
WRITE_WORDS = {
    "set", "output", "card", "connect", "disconnect", "up", "down", "delete",
    "modify", "start", "stop", "restart", "enable", "disable", "kill",
    "dispatch", "keyword", "reload", "remove", "pair", "trust", "power",
    "add", "del", "flush", "replace", "change", "append", "prepend",  # ip
    "--pre",  # rg runs this as a preprocessor
    "--output",  # sort
}
WRITE_PREFIXES = ("set-", "move-", "load-", "unload-", "suspend-", "--vacuum",
                  "--rotate", "--flush", "--relinquish", "--setup-keys", "--update-catalog")


def writes(arg: str) -> bool:
    a = arg.split("=", 1)[0]
    return a in WRITE_WORDS or a.startswith(WRITE_PREFIXES)


def read_only(command: str) -> bool:
    if any(s in command for s in ("`", "$(", "<(", ">(")):
        return False
    try:
        lex = shlex.shlex(command, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:
        return False

    segments, current, i = [], [], 0
    while i < len(tokens):
        tok = tokens[i]
        nxt = tokens[i + 1] if i + 1 < len(tokens) else ""
        if tok in ("|", "&&", "||", ";"):
            segments.append(current)
            current = []
        elif tok in (">", ">>", "&>") and nxt == "/dev/null":
            i += 1  # discarding output is fine; writing a file is not
        elif tok == ">&" and nxt in ("1", "2"):
            i += 1
        elif tok and set(tok) <= set("|&;<>()"):
            return False  # other redirection, backgrounding, subshells
        else:
            current.append(tok)
        i += 1
    segments.append(current)

    for argv in segments:
        argv = [a for a in argv if a not in ("1", "2")]  # fd numbers left by 2>/dev/null
        if not argv or argv[0] not in READ_ONLY:
            return False
        if any(writes(a) for a in argv[1:]):
            return False
        # sort -o FILE, also bundled as -uo FILE
        if argv[0] == "sort" and any(re.fullmatch(r"-[a-zA-Z]*o.*", a) for a in argv[1:]):
            return False
        allowed = READ_ONLY[argv[0]]
        if callable(allowed):
            if not allowed(argv):
                return False
        elif allowed is not None and len(argv) > 1 and argv[1] not in allowed:
            return False
    return True


def system_prompt() -> str:
    tools = [t for t in KNOWN_TOOLS if shutil.which(t)]
    facts = [
        f"OS: NixOS ({platform.release()}), host {platform.node()}, user {os.environ.get('USER', '?')}",
        f"Desktop: {os.environ.get('XDG_CURRENT_DESKTOP') or 'unknown'} "
        f"({os.environ.get('XDG_SESSION_TYPE') or 'unknown'} session)",
        f"Shell: {os.environ.get('SHELL', 'sh')}, cwd {os.getcwd()}",
        f"Time: {time.strftime('%Y-%m-%d %H:%M %Z')}",
        f"Available: {' '.join(tools)}",
    ]
    hints = HINTS.read_text().strip() if HINTS.exists() else ""
    return f"""You operate a Linux machine for the user through the run_shell tool.

{chr(10).join(facts)}

Rules:
- Look before you change anything: query current state first, then act.
- Prefer machine-readable output (-j, -f json, -t) and filter it with jq.
- One command per call. Keep commands short; the user reads each one.
- Read-only commands built from ls/cat/grep/jq/sort/head/cut/ps/df/wpctl status
  and the like run instantly; anything else (awk, sed, find, writes) makes the
  user approve it, so prefer the first kind when it can do the job.
- NixOS: a missing program can be run with `nix run nixpkgs#<pkg> -- <args>`.
  Never edit files under /etc or the nix store, never use sudo.
- If a command fails, read the error and try a different approach. Never run
  the same command twice.
- When the task is done (or impossible), stop calling tools and reply with ONE
  short sentence saying what you changed. No markdown.

Recipes (use these when they fit, instead of working it out):
- Wifi network name: `nmcli -t -f active,ssid dev wifi | grep '^yes'`
- Local addresses: `ip -br addr`. Public IP: `curl -s ifconfig.me`
- Biggest store paths in the system closure (column 2 is the path's own size,
  column 3 its closure):
  `nix path-info -rsS /run/current-system | sort -k2 -n | tail -n 10 | numfmt --field=2,3 --to=iec`
- NixOS generations: `nixos-rebuild list-generations`. What changed between
  two: `nix store diff-closures /nix/var/nix/profiles/system-<A>-link /nix/var/nix/profiles/system-<B>-link`
- Failed units: `systemctl --failed` and `systemctl --user --failed`, then
  `journalctl -u <unit> -n 30 --no-pager` (add --user for user units)
- What listens on a port: `ss -ltnp`
- What fills a directory: `du -sh <dir>/* | sort -h | tail`
{chr(10) + hints if hints else ''}"""


TOOLS = [{
    "type": "function",
    "function": {
        "name": "run_shell",
        "description": "Run a bash command and return its combined stdout and stderr.",
        "parameters": {
            "type": "object",
            "properties": {"command": {"type": "string"}},
            "required": ["command"],
        },
    },
}]


def color(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if sys.stderr.isatty() else text


class Spinner:
    """A dot on stderr while waiting; the first call can include a model load."""

    def __init__(self):
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        frames, i = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏", 0
        while not self.stop.wait(0.1):
            sys.stderr.write(f"\r{color('2', frames[i % len(frames)])} ")
            sys.stderr.flush()
            i += 1

    def __enter__(self):
        if sys.stderr.isatty():
            self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        if self.thread.is_alive():
            self.thread.join()
            sys.stderr.write("\r\033[K")


def chat(messages: list, tools: bool = True) -> dict:
    body = json.dumps({
        "model": MODEL,
        "messages": messages,
        **({"tools": TOOLS} if tools else {}),
        "temperature": 0.3,
    }).encode()
    req = urllib.request.Request(
        f"{URL}/chat/completions", body, {"Content-Type": "application/json"}
    )
    with Spinner():
        with urllib.request.urlopen(req, timeout=300) as resp:
            return json.load(resp)["choices"][0]["message"]


def ask(prompt: str) -> str:
    # The prompt must reach a person even when stdin is a pipe.
    try:
        with open("/dev/tty") as tty:
            sys.stderr.write(prompt)
            sys.stderr.flush()
            return tty.readline().strip().lower()
    except OSError:
        return "n"


def run(command: str) -> str:
    try:
        proc = subprocess.run(
            ["bash", "-c", command], capture_output=True, text=True, timeout=60,
            stdin=subprocess.DEVNULL,
        )
        out = (proc.stdout + proc.stderr).strip()
        if proc.returncode:
            out += f"\n[exit {proc.returncode}]"
    except subprocess.TimeoutExpired:
        out = "[timed out after 60s]"
    if len(out) > MAX_OUTPUT:
        half = MAX_OUTPUT // 2
        out = f"{out[:half]}\n[... {len(out) - MAX_OUTPUT} chars cut ...]\n{out[-half:]}"
    return out or "[no output]"


def unload() -> int:
    """`cerbo off`: free the VRAM now instead of waiting out llama-swap's ttl."""
    root = URL.removesuffix("/").removesuffix("/v1")
    try:
        with urllib.request.urlopen(f"{root}/running", timeout=5) as resp:
            running = [m["model"] for m in json.load(resp).get("running", [])]
        if running:
            urllib.request.urlopen(f"{root}/unload", timeout=30).close()
    except (urllib.error.URLError, TimeoutError, ValueError, KeyError) as e:
        print(color("31", f"cerbo: could not unload via {root}: {e}"), file=sys.stderr)
        return 1
    print(f"unloaded {', '.join(running)}" if running else "nothing loaded")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="Do something in the shell via the local model.")
    p.add_argument("-y", "--yes", action="store_true", help="run every command without asking")
    p.add_argument("-v", "--verbose", action="store_true", help="show command output")
    p.add_argument("task", nargs="+", help="what to do, or `off` to unload the model")
    args = p.parse_args()
    if args.task == ["off"]:
        return unload()

    messages = [
        {"role": "system", "content": system_prompt()},
        {"role": "user", "content": " ".join(args.task)},
    ]
    changed, ran = [], set()

    for _ in range(MAX_STEPS):
        try:
            msg = chat(messages)
        except (urllib.error.URLError, TimeoutError) as e:
            print(color("31", f"cerbo: model unreachable at {URL} (server or tunnel down?): {e}"),
                  file=sys.stderr)
            return 1
        messages.append(msg)

        calls = msg.get("tool_calls") or []
        if not calls:
            # Told not to, it still bolds things now and then.
            reply = (msg.get("content") or "").replace("**", "").strip()
            print(reply or "(no reply)")
            if changed:
                print(color("2", "ran: " + " ; ".join(changed)), file=sys.stderr)
            return 0

        for call in calls:
            try:
                command = json.loads(call["function"]["arguments"])["command"]
            except (KeyError, json.JSONDecodeError):
                result = "error: arguments must be JSON with a 'command' string"
            else:
                if command in ran:
                    # 9B models loop. Answering for them breaks the loop
                    # without costing the user a prompt.
                    result = ("You already ran exactly this command; its output is above. "
                              "Do something different, or answer with what you know.")
                    messages.append({"role": "tool", "tool_call_id": call.get("id", ""),
                                     "content": result})
                    continue
                ran.add(command)
                safe = read_only(command)
                print(color("2" if safe else "1;33", f"$ {command}"), file=sys.stderr)
                answer = "y" if safe or args.yes else ask(color("1", "run? [Y/n/q] "))
                if answer == "q":
                    return 130
                if answer in ("", "y", "yes"):
                    result = run(command)
                    if not safe:
                        changed.append(command)
                    if args.verbose:
                        print(color("2", result), file=sys.stderr)
                else:
                    result = "The user declined this command. Try another way, or stop and say why."
            messages.append({
                "role": "tool",
                "tool_call_id": call.get("id", ""),
                "content": result,
            })

    # Out of steps: one last call with no tools, so the user still gets
    # whatever it found instead of nothing.
    print(color("31", f"cerbo: out of steps after {MAX_STEPS}"), file=sys.stderr)
    messages.append({"role": "user", "content": (
        "Step limit reached. Without running anything else, say in one or two "
        "sentences what you found and what is still unresolved.")})
    try:
        reply = (chat(messages, tools=False).get("content") or "").replace("**", "").strip()
    except (urllib.error.URLError, TimeoutError):
        reply = ""
    if reply:
        print(reply)
    if changed:
        print(color("2", "ran: " + " ; ".join(changed)), file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
