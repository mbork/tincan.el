#!/usr/bin/env python3
# * tincan
# Print (and, with --follow, keep watching) a Claude Code session transcript as
# plain, font-lockable text on stdout.  See DECISIONS.md for design notes.

# * Imports
import argparse
import json
import os
import shlex
import shutil
import sys
import time
from datetime import datetime
from pathlib import Path

# * Configuration
# ** Section markers
# Rare-at-beginning-of-line prefixes so the Emacs side can font-lock reliably.
ROLE_USER = "@@@ USER"
ROLE_ASSISTANT = "@@@ ASSISTANT"
ROLE_THINKING = "@@@ THINKING"
ROLE_TOOL_USE = "@@@ TOOL_USE"
ROLE_TOOL_RESULT = "@@@ TOOL_RESULT"
ROLE_DONE = "@@@ DONE"

# ** Polling
POLL_INTERVAL_SECONDS = 0.25

# * Output helpers
def emit(text):
    # Append-only writes to stdout, flushed so a downstream reader sees them.
    sys.stdout.write(text)
    sys.stdout.flush()

def die(message):
    sys.stderr.write(message.rstrip("\n") + "\n")
    sys.exit(1)

# * Session discovery
def get_config_dir():
    env_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    if env_dir:
        return Path(env_dir)
    return Path.home() / ".claude"

def get_projects_root():
    return get_config_dir() / "projects"

def iter_session_files():
    root = get_projects_root()
    if not root.is_dir():
        return []
    return sorted(root.glob("*/*.jsonl"))

def resolve_session_file(session_arg):
    # A direct path wins.
    candidate = Path(session_arg)
    if candidate.is_file():
        return candidate
    # Otherwise treat the argument as a session id or a unique id prefix.
    matches = [path for path in iter_session_files()
               if path.stem == session_arg or path.stem.startswith(session_arg)]
    exact = [path for path in matches if path.stem == session_arg]
    if exact:
        return exact[0]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        die("No session matching {!r} found under {}".format(
            session_arg, get_projects_root()))
    die("Ambiguous session prefix {!r}; matches:\n{}".format(
        session_arg, "\n".join(path.stem for path in matches)))

# * Rendering
# ** Block formatting
def longest_backtick_run(text):
    longest = 0
    current = 0
    for character in text:
        if character == "`":
            current += 1
            longest = max(longest, current)
        else:
            current = 0
    return longest

def fence_body(body, lang):
    # Use a fence longer than any backtick run inside BODY so embedded
    # backticks or fences cannot terminate the block early (CommonMark rule).
    fence = "`" * max(3, longest_backtick_run(body) + 1)
    return fence + lang + "\n" + body + "\n" + fence

def format_block(header, body, lang=None):
    body = body.strip("\n")
    if not body.strip():
        # Skip empty blocks (e.g. thinking whose text was not persisted).
        return None
    # LANG=None means render the body as-is; any string fences it (the empty
    # string makes a plain, language-less code block).
    if lang is not None:
        body = fence_body(body, lang)
    return header + "\n" + body + "\n\n"

def get_content(record):
    message = record.get("message")
    if isinstance(message, dict):
        return message.get("content")
    return None

# ** Tool blocks
def render_tool_use(block):
    name = block.get("name", "?")
    tool_input = block.get("input")
    if tool_input is None:
        body = ""
    else:
        body = json.dumps(tool_input, indent=2, ensure_ascii=False)
    return format_block(ROLE_TOOL_USE + " " + name, body, lang="json")

def render_tool_result(block):
    # A tool_result's content is either a plain string or a list of text blocks.
    content = block.get("content")
    if isinstance(content, str):
        body = content
    elif isinstance(content, list):
        texts = [sub.get("text", "") for sub in content
                 if isinstance(sub, dict) and sub.get("type") == "text"]
        body = "\n".join(texts)
    else:
        body = ""
    header = ROLE_TOOL_RESULT
    if block.get("is_error"):
        # Mark errors on the marker line, not inside the fenced body.
        header = ROLE_TOOL_RESULT + " (error)"
    return format_block(header, body, lang="")

# ** User and assistant records
def render_user_block(block):
    block_type = block.get("type") if isinstance(block, dict) else None
    if block_type == "text":
        return format_block(ROLE_USER, block.get("text", ""))
    if block_type == "tool_result":
        # Tool results are delivered to the model as a "user" message (API shape).
        return render_tool_result(block)
    return None

def render_user(record):
    content = get_content(record)
    parts = []
    if isinstance(content, str):
        rendered = format_block(ROLE_USER, content)
        if rendered:
            parts.append(rendered)
    elif isinstance(content, list):
        for block in content:
            rendered = render_user_block(block)
            if rendered:
                parts.append(rendered)
    return "".join(parts) if parts else None

def render_assistant_block(block):
    block_type = block.get("type") if isinstance(block, dict) else None
    if block_type == "text":
        return format_block(ROLE_ASSISTANT, block.get("text", ""))
    if block_type == "thinking":
        return format_block(ROLE_THINKING, block.get("thinking", ""))
    if block_type == "tool_use":
        return render_tool_use(block)
    return None

def render_assistant(record):
    content = get_content(record)
    parts = []
    if isinstance(content, str):
        rendered = format_block(ROLE_ASSISTANT, content)
        if rendered:
            parts.append(rendered)
    elif isinstance(content, list):
        for block in content:
            rendered = render_assistant_block(block)
            if rendered:
                parts.append(rendered)
    return "".join(parts) if parts else None

# ** System records
def render_system(record):
    # A "turn_duration" system record is emitted exactly once at the end of a
    # turn; render it as a standalone marker so Emacs can both show it and use
    # it to tell that the agent has finished.
    if record.get("subtype") == "turn_duration":
        seconds = round(record.get("durationMs", 0) / 1000)
        return "{} ({}s)\n\n".format(ROLE_DONE, seconds)
    return None

# ** Record dispatch
def render_record(record):
    record_type = record.get("type")
    if record_type == "user":
        return render_user(record)
    if record_type == "assistant":
        return render_assistant(record)
    if record_type == "system":
        return render_system(record)
    return None

def emit_record(record):
    text = render_record(record)
    if text:
        emit(text)

# * Line handling
def handle_line(line):
    line = line.strip()
    if not line:
        return
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        # Resilience: skip malformed or incomplete JSON.
        return
    emit_record(record)

# * Transcript printing
def print_transcript(path):
    with open(path, encoding="utf-8", errors="replace") as transcript:
        for line in transcript:
            handle_line(line)

# * Follow mode
def follow_transcript(path):
    # Drain the current contents, then poll for newly appended whole lines.
    # Claude Code session files are append-only, so a simple read offset is
    # enough.  Only newline-terminated lines are processed, so a partially
    # written record is never parsed; handle_line additionally tolerates bad
    # JSON.
    with open(path, encoding="utf-8", errors="replace") as transcript:
        while True:
            position = transcript.tell()
            line = transcript.readline()
            if line.endswith("\n"):
                handle_line(line)
            else:
                # No complete line yet (partial write or EOF): rewind and wait.
                transcript.seek(position)
                time.sleep(POLL_INTERVAL_SECONDS)

# * Session listing
# ** Metadata extraction
def read_session_meta(path):
    cwd = None
    custom_title = None
    ai_title = None
    timestamp = None
    first_prompt = None
    with open(path, encoding="utf-8", errors="replace") as transcript:
        for line in transcript:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if cwd is None and record.get("cwd"):
                cwd = record["cwd"]
            if timestamp is None and record.get("timestamp"):
                timestamp = record["timestamp"]
            # A /rename writes a "custom-title" record; keep the latest of each
            # title kind and prefer the user's custom title below.
            if record.get("type") == "custom-title" and record.get("customTitle"):
                custom_title = record["customTitle"]
            if record.get("type") == "ai-title" and record.get("aiTitle"):
                ai_title = record["aiTitle"]
            if first_prompt is None and record.get("type") == "user":
                content = get_content(record)
                if isinstance(content, str) and content.strip():
                    first_prompt = content.strip()
    title = custom_title or ai_title or first_prompt or path.stem
    return {"id": path.stem, "cwd": cwd, "title": title, "timestamp": timestamp}

# ** Formatting
def format_timestamp(timestamp):
    if not timestamp:
        return "?"
    try:
        parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        return timestamp
    return parsed.astimezone().isoformat(timespec="seconds")

def oneline(text, limit=70):
    flattened = " ".join(text.split())
    if len(flattened) > limit:
        return flattened[:limit - 3] + "..."
    return flattened

# ** Listing
def is_ancestor(parent, child):
    # True if PARENT equals CHILD or is an ancestor of it (path-component aware,
    # so /a/b is not treated as an ancestor of /a/bc).  Both are physical paths
    # (os.getcwd() and the recorded cwd resolve symlinks), so this is symlink
    # safe without extra work.
    try:
        return os.path.commonpath([parent, child]) == parent
    except ValueError:
        return False

def show_sessions(show_all=False):
    metas = [read_session_meta(path) for path in iter_session_files()]
    if show_all:
        selected = metas
    else:
        # Sessions launched at or above the working directory; among those, list
        # the ones from the closest launch directory (the deepest matching cwd),
        # so the command works from any subdirectory of the project.
        here = os.getcwd()
        ancestors = [m for m in metas if m["cwd"] and is_ancestor(m["cwd"], here)]
        root = max((m["cwd"] for m in ancestors), key=len, default=None)
        selected = [m for m in ancestors if m["cwd"] == root] if root else []
    selected.sort(key=lambda meta: meta["timestamp"] or "", reverse=True)
    for meta in selected:
        line = "{}\t{}\t{}\t{}\n".format(
            meta["id"], format_timestamp(meta["timestamp"]),
            oneline(meta["title"]), meta["cwd"] or "")
        emit(line)

# * Notification hook
# ** Status file written by the hook
def get_tincan_state_dir():
    return get_config_dir() / "tincan"

def notify_status_path(session_id):
    return get_tincan_state_dir() / (session_id + ".notify")

def run_notification_hook():
    # Invoked as a Claude Code "Notification" hook; the event JSON arrives on
    # stdin.  Write the message to a small per-session file so Emacs can show
    # that Claude is waiting for input.  Must never disrupt Claude Code, so any
    # problem is swallowed silently.
    try:
        event = json.loads(sys.stdin.read())
    except (ValueError, OSError):
        return
    session_id = event.get("session_id")
    if not session_id:
        return
    message = event.get("message") or "Claude needs your input"
    try:
        path = notify_status_path(session_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(message + "\n", encoding="utf-8")
    except OSError:
        return

# ** Installing the hook into settings.json
def default_settings_path():
    # Project-local, personal (typically gitignored) settings, resolved against
    # the working directory - the same place Claude Code reads project settings,
    # so the hook fires only for this project's sessions.
    return Path.cwd() / ".claude" / "settings.local.json"

def hook_command():
    # The command Claude Code runs on a Notification event: python3 plus this
    # script's own absolute path, so it does not depend on the executable bit.
    script = os.path.realpath(__file__)
    return "python3 {} --notification-hook".format(shlex.quote(script))

def load_settings(path):
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    if not text.strip():
        return {}
    return json.loads(text)

def save_settings(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    serialized = json.dumps(data, indent=2, ensure_ascii=False)
    path.write_text(serialized + "\n", encoding="utf-8")

def backup_settings(path):
    if path.exists():
        shutil.copyfile(path, str(path) + ".bak")

def notification_commands(data):
    groups = data.get("hooks", {}).get("Notification", [])
    commands = []
    for group in groups:
        for hook in group.get("hooks", []):
            command = hook.get("command")
            if command:
                commands.append(command)
    return commands

def install_hook(settings_path):
    data = load_settings(settings_path)
    command = hook_command()
    if command in notification_commands(data):
        print("tincan: Notification hook already installed in {}".format(settings_path))
        return 0
    backup_settings(settings_path)
    hooks = data.setdefault("hooks", {})
    notifications = hooks.setdefault("Notification", [])
    notifications.append({"matcher": "", "hooks": [{"type": "command", "command": command}]})
    save_settings(settings_path, data)
    print("tincan: installed Notification hook in {} - "
          "restart Claude Code or run /hooks to load it".format(settings_path))
    return 0

def uninstall_hook(settings_path):
    data = load_settings(settings_path)
    command = hook_command()
    if command not in notification_commands(data):
        print("tincan: Notification hook not present in {}".format(settings_path))
        return 0
    backup_settings(settings_path)
    hooks = data.get("hooks", {})
    groups = hooks.get("Notification", [])
    kept = [group for group in groups
            if not any(hook.get("command") == command for hook in group.get("hooks", []))]
    # Prune empty containers so an install/uninstall cycle round-trips cleanly.
    if kept:
        hooks["Notification"] = kept
    else:
        hooks.pop("Notification", None)
    if not hooks:
        data.pop("hooks", None)
    save_settings(settings_path, data)
    print("tincan: removed Notification hook from {}".format(settings_path))
    return 0

def check_hook(settings_path):
    data = load_settings(settings_path)
    if hook_command() in notification_commands(data):
        print("installed")
        return 0
    print("not installed")
    return 1

# * Command-line interface
def build_parser():
    parser = argparse.ArgumentParser(
        description="Print or follow a Claude Code session transcript as plain text.")
    parser.add_argument(
        "session", nargs="?",
        help="session id, unique id prefix, or path to a .jsonl transcript")
    parser.add_argument(
        "-f", "--follow", action="store_true",
        help="keep watching the session and append new output (like tail -f)")
    parser.add_argument(
        "--show-sessions", action="store_true",
        help="list sessions (id, timestamp, title, cwd) and exit")
    parser.add_argument(
        "--all", action="store_true",
        help="with --show-sessions, list every project's sessions, not just here")
    parser.add_argument(
        "--notification-hook", action="store_true",
        help="run as a Claude Code Notification hook (reads event JSON on stdin)")
    parser.add_argument(
        "--install-hook", action="store_true",
        help="install the Notification hook into the settings file and exit")
    parser.add_argument(
        "--uninstall-hook", action="store_true",
        help="remove the Notification hook from the settings file and exit")
    parser.add_argument(
        "--check-hook", action="store_true",
        help="exit 0 if the Notification hook is installed, 1 otherwise")
    parser.add_argument(
        "--settings-file", metavar="PATH",
        help="settings file to manage (default: .claude/settings.local.json in the cwd)")
    return parser

def main():
    parser = build_parser()
    args = parser.parse_args()
    if args.notification_hook:
        run_notification_hook()
        return
    if args.install_hook or args.uninstall_hook or args.check_hook:
        if args.settings_file:
            settings_path = Path(args.settings_file)
        else:
            settings_path = default_settings_path()
        if args.install_hook:
            sys.exit(install_hook(settings_path))
        if args.uninstall_hook:
            sys.exit(uninstall_hook(settings_path))
        sys.exit(check_hook(settings_path))
    if args.show_sessions:
        show_sessions(args.all)
        return
    if not args.session:
        parser.error("a session id is required (or use --show-sessions)")
    path = resolve_session_file(args.session)
    if args.follow:
        follow_transcript(path)
    else:
        print_transcript(path)

# * Entry point
if __name__ == "__main__":
    reconfigure_stdout = getattr(sys.stdout, "reconfigure", None)
    if reconfigure_stdout is not None:
        reconfigure_stdout(encoding="utf-8", errors="replace")
    try:
        main()
    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except Exception:
            pass
