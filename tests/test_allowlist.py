"""Which commands cerbo runs without asking. Run: python3 tests/test_allowlist.py"""

import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("cerbo", Path(__file__).parent.parent / "cerbo.py")
cerbo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cerbo)

READ_ONLY = [
    "jay randr show", "wpctl status", "pactl -f json list sinks | jq -r .[].name",
    "ls ~ 2>/dev/null", "pactl list sinks 2>&1 | grep -i hdmi", "journalctl --user -n 20",
    "sort -u", "grep -o foo f", "systemctl --user status foo", "systemctl --failed", "ss -ltnp",
    "du -sh ~/.cache/* | sort -h | tail",
    "nmcli -t -f active,ssid dev wifi | grep ^yes", "ip -br addr", "ip route",
    "nix path-info -rsS /run/current-system | sort -k2 -n | tail -n 10 | numfmt --field=2,3 --to=iec",
    "nix store diff-closures /a /b", "nix-store -qR /run/current-system",
    "nix-store --query --requisites x", "nixos-rebuild list-generations",
    "cd /x && ls -la", "cd /a && git remote -v",
    "git status", "git -C /a/b status -sb", "git --no-pager log --oneline -5", "git diff HEAD~1",
    "git show HEAD:README.md", "git branch", "git branch -a -vv", "git tag", "git remote -v",
    "git remote show origin", "git stash list", "git config --get user.name", "git reflog",
    "git worktree list", "git rev-parse --show-toplevel", "git ls-remote origin",
    "swaymsg -t get_outputs -r", "niri msg outputs", "wlr-randr", "xrandr --query",
]

ASKS = [
    "pactl set-default-sink foo", "pactl -f json set-default-sink x", "wpctl set-default 42",
    "jay randr output DP-2 enable", "env rm -rf x", "ls > out", "cat a; rm b", "echo $(rm x)",
    "sort -uo f x", "rg --pre=sh x", "journalctl --vacuum-size=1M", "systemctl --user stop foo",
    "fd -x rm", "ls &", "nix run nixpkgs#foo", "nmcli dev wifi connect x", "nmcli con up x",
    "ip addr add 1.2.3.4/24 dev x", "ip link set x down", "nix store delete /x", "nix eval x",
    "nix build x", "nix", "nix-store --delete x", "nix-store --gc", "nixos-rebuild switch",
    "curl -s ifconfig.me", "cd /x && rm -rf y",
    "git branch newthing", "git branch -D x", "git tag v1", "git remote add o u",
    "git remote set-url o u", "git stash", "git stash drop", "git config user.name x",
    "git -c core.pager=rm log", "git grep -O foo", "git log --output=f", "git commit -m x",
    "git push", "git rm -r --cached x", "git fetch", "git reset --hard", "git checkout x",
    "git clean -fd", "git reflog expire --all", "git worktree add x", "git -C", "git",
    "swaymsg exit", "swaymsg -t command exit", "niri msg action quit",
    "wlr-randr --output X --off", "xrandr --output X --off",
]

wrong = [c for c in READ_ONLY if not cerbo.read_only(c)] + [c for c in ASKS if cerbo.read_only(c)]
for c in wrong:
    print("misclassified:", c)
print(f"{len(READ_ONLY) + len(ASKS) - len(wrong)}/{len(READ_ONLY) + len(ASKS)} ok")
sys.exit(1 if wrong else 0)
