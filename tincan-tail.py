#!/usr/bin/env python3
# * tincan-tail
# Print (and, with --follow, keep watching) a Claude Code session transcript as
# plain, font-lockable text on stdout.  See DECISIONS.md for design notes.

# * Imports
import argparse
import json
import os
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
def format_block(header, body):
    body = body.strip("\n")
    if not body.strip():
        # Skip empty blocks (e.g. thinking whose text was not persisted).
        return None
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
    return format_block(ROLE_TOOL_USE + " " + name, body)

def render_tool_result(block):
    content = block.get("content")
    if isinstance(content, str):
        body = content
    elif isinstance(content, list):
        texts = [sub.get("text", "") for sub in content
                 if isinstance(sub, dict) and sub.get("type") == "text"]
        body = "\n".join(texts)
    else:
        body = ""
    if block.get("is_error"):
        body = "[error]\n" + body
    return format_block(ROLE_TOOL_RESULT, body)

# ** User and assistant records
def render_user_block(block):
    block_type = block.get("type") if isinstance(block, dict) else None
    if block_type == "text":
        return format_block(ROLE_USER, block.get("text", ""))
    if block_type == "tool_result":
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

# ** Record dispatch
def render_record(record):
    record_type = record.get("type")
    if record_type == "user":
        return render_user(record)
    if record_type == "assistant":
        return render_assistant(record)
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
    title = None
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
            if record.get("type") == "ai-title" and record.get("aiTitle"):
                title = record["aiTitle"]
            if first_prompt is None and record.get("type") == "user":
                content = get_content(record)
                if isinstance(content, str) and content.strip():
                    first_prompt = content.strip()
    if not title:
        title = first_prompt or path.stem
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
def show_sessions():
    here = os.getcwd()
    metas = [read_session_meta(path) for path in iter_session_files()]
    mine = [meta for meta in metas if meta["cwd"] == here]
    mine.sort(key=lambda meta: meta["timestamp"] or "", reverse=True)
    for meta in mine:
        line = "{}\t{}\t{}\n".format(
            meta["id"], format_timestamp(meta["timestamp"]), oneline(meta["title"]))
        emit(line)

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
        help="list this project's sessions (id, timestamp, title) and exit")
    return parser

def main():
    parser = build_parser()
    args = parser.parse_args()
    if args.show_sessions:
        show_sessions()
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
