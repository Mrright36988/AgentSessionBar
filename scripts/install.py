#!/usr/bin/python3
"""Install or remove AgentSessionBar's hooks for Claude Code and Codex.

  install    copy agentsessionbar-hook to ~/.agentsessionbar/bin, back up ~/.claude/settings.json and
             ~/.codex/hooks.json, then append AgentSessionBar's hook groups (existing hooks are kept)
  uninstall  drop every hook that runs agentsessionbar-hook (or deck-hook, from before the rename); if what
             remains equals the backup, copy the backup back so the file is byte-identical to before
  status     which events are installed, and which Codex hooks still need trusting
  doctor     status plus whether the AgentSessionBar app is reachable

Runs from a clone (scripts/install.py) or from inside the app
(AgentSessionBar.app/Contents/Resources/scripts/install.py); the hook is found at ../hook/ in both.
"""
import collections
import glob
import json
import os
import re
import shutil
import socket
import stat
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
HOME = os.path.expanduser("~")

Paths = collections.namedtuple("Paths", "claude_settings codex_hooks codex_config shim_src shim_dst socket legacy_shim")
DEFAULT = Paths(
    claude_settings=os.path.join(HOME, ".claude/settings.json"),
    codex_hooks=os.path.join(HOME, ".codex/hooks.json"),
    codex_config=os.path.join(HOME, ".codex/config.toml"),
    shim_src=os.path.join(HERE, "..", "hook", "agentsessionbar_hook.py"),
    shim_dst=os.path.join(HOME, ".agentsessionbar/bin/agentsessionbar-hook"),
    socket=os.path.join(HOME, "Library/Application Support/AgentSessionBar/hook.sock"),
    legacy_shim=os.path.join(HOME, ".agent-deck/bin/deck-hook"),
)
MARK = "/.agentsessionbar/bin/agentsessionbar-hook"
# Hooks installed before the project was renamed from agent-deck (2026-11-07). They count as ours, so
# uninstall removes them and install asks for an uninstall first. Drop this once nobody has them.
LEGACY_MARK = "/.agent-deck/bin/deck-hook"

# event -> (timeout seconds, run in background). Only PermissionRequest blocks: it waits for an answer.
# No SessionEnd for Claude Code: Cursor also runs the hooks in ~/.claude/settings.json for its own agent and
# holds a closing window until its SessionEnd hooks finish, which can hang. The app drops an ended Claude
# session on its next scan of ~/.claude/sessions anyway.
CLAUDE_EVENTS = {
    "SessionStart": (10, True),
    "UserPromptSubmit": (10, True),
    "PermissionRequest": (600, False),
    "PostToolUse": (10, True),
    "Stop": (10, True),
    "StopFailure": (10, True),
}
CODEX_EVENTS = {  # Codex hooks have no background mode; agentsessionbar-hook returns at once for these anyway
    "SessionStart": (10, False),
    "SessionEnd": (2, False),
    "UserPromptSubmit": (10, False),
    "PermissionRequest": (600, False),
    "PostToolUse": (10, False),
    "Stop": (10, False),
}


def plan(paths, tool, events):
    groups = {}
    for event, (timeout, background) in events.items():
        hook = {"type": "command", "command": "/usr/bin/python3 %s %s %s" % (paths.shim_dst, tool, event), "timeout": timeout}
        if background:
            hook["async"] = True
        groups[event] = [{"hooks": [hook]}]
    return groups


def targets(paths):
    return [(paths.claude_settings, plan(paths, "claude", CLAUDE_EVENTS)),
            (paths.codex_hooks, plan(paths, "codex", CODEX_EVENTS))]


def load(path):
    with open(path) as f:
        return json.load(f)


def save(path, data):
    tmp = path + ".agentsessionbar.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def is_legacy(hook):
    return LEGACY_MARK in (hook.get("command") or "")


def is_ours(hook):
    return MARK in (hook.get("command") or "") or is_legacy(hook)


def installed(data, match=is_ours):
    return [event for event, groups in data.get("hooks", {}).items()
            for group in groups for hook in group.get("hooks", []) if match(hook)]


def strip(data):
    hooks = data.get("hooks", {})
    for event in list(hooks):
        kept = []
        for group in hooks[event]:
            group = dict(group, hooks=[h for h in group.get("hooks", []) if not is_ours(h)])
            if group["hooks"]:
                kept.append(group)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    return data


def install(paths=DEFAULT):
    for path, _ in targets(paths):
        if os.path.exists(path) and installed(load(path)):
            sys.exit("AgentSessionBar hooks (or old agent-deck ones) are already in %s; run uninstall first" % path)
    os.makedirs(os.path.dirname(paths.shim_dst), exist_ok=True)
    shutil.copyfile(paths.shim_src, paths.shim_dst)
    os.chmod(paths.shim_dst, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)
    stamp = time.strftime("%Y%m%d%H%M%S")
    for path, events in targets(paths):
        if os.path.exists(path):
            shutil.copy2(path, "%s.bak.agentsessionbar-%s" % (path, stamp))
            data = load(path)
        else:
            data = {}
        hooks = data.setdefault("hooks", {})
        for event, groups in events.items():
            hooks.setdefault(event, []).extend(groups)
        save(path, data)
        print("installed %d events into %s" % (len(events), path))
    print("\nCodex only runs hooks you have trusted: open Codex settings > Hooks in Cursor and trust the")
    print("AgentSessionBar entries (agentsessionbar-hook). Run `install.py status` afterwards to check.")


def uninstall(paths=DEFAULT):
    for path, _ in targets(paths):
        if not os.path.exists(path) or not installed(load(path)):
            print("nothing to remove in %s" % path)
            continue
        data = strip(load(path))
        backups = sorted(glob.glob(path + ".bak.agentsessionbar-*")) or sorted(glob.glob(path + ".bak.agent-deck-*"))
        if backups and load(backups[-1]) == data:
            shutil.copy2(backups[-1], path)
            print("restored %s byte-for-byte from %s" % (path, os.path.basename(backups[-1])))
        else:
            save(path, data)
            print("removed AgentSessionBar hooks from %s; other edits made since install were kept" % path)
    for shim in (paths.shim_dst, paths.legacy_shim):
        if os.path.exists(shim):
            os.remove(shim)


def snake(name):
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def codex_trust(paths):
    """Maps each of our Codex hooks to whether config.toml records a trusted hash for its slot."""
    if not os.path.exists(paths.codex_hooks):
        return {}
    trusted = set()
    if os.path.exists(paths.codex_config):
        current = None
        with open(paths.codex_config) as f:
            for line in f:
                header = re.match(r'\s*\[hooks\.state\."(.+)"\]\s*$', line)
                if header:
                    current = header.group(1)
                elif line.lstrip().startswith("["):
                    current = None
                elif current and re.match(r"\s*trusted_hash\s*=", line):
                    trusted.add(current)
    result = {}
    for event, groups in load(paths.codex_hooks).get("hooks", {}).items():
        for g, group in enumerate(groups):
            for h, hook in enumerate(group.get("hooks", [])):
                if is_ours(hook):
                    key = "%s:%s:%d:%d" % (paths.codex_hooks, snake(event), g, h)
                    result[event] = key in trusted
    return result


def status(paths=DEFAULT):
    for path, _ in targets(paths):
        data = load(path) if os.path.exists(path) else {}
        print("%s -> %s" % (path, installed(data) or "none"))
        if installed(data, is_legacy):
            print("  old agent-deck hooks still here: run `install.py uninstall`, then `install.py install`")
    trust = codex_trust(paths)
    if trust:
        pending = sorted(e for e, ok in trust.items() if not ok)
        print("codex trust -> %s" % ("all trusted" if not pending else "not yet trusted: %s" % ", ".join(pending)))
    print("agentsessionbar-hook -> %s" % ("present" if os.path.exists(paths.shim_dst) else "missing"))


def doctor(paths=DEFAULT):
    status(paths)
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.settimeout(0.2)
        conn.connect(paths.socket)
        print("AgentSessionBar app -> reachable")
    except OSError as error:
        print("AgentSessionBar app -> not reachable (%s); hooks pass through until it runs" % error.strerror)
    finally:
        conn.close()


if __name__ == "__main__":
    commands = {"install": install, "uninstall": uninstall, "status": status, "doctor": doctor}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        sys.exit("usage: install.py install|uninstall|status|doctor")
    commands[sys.argv[1]]()
