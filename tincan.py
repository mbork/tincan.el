#!/usr/bin/env python3
# * tincan
# Print (and, with --follow, keep watching) a Claude Code session transcript as
# plain, font-lockable text on stdout.  See DECISIONS.md for design notes.

# * Imports
import argparse
import difflib
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
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

# ** Record framing
# In --follow mode every rendered record is terminated with an ASCII record
# separator, so the Emacs filter can buffer partial pipe chunks and insert
# whole records only - a code fence then always arrives together with its
# closing fence (D47).
RECORD_SEPARATOR = "\x1e"
frame_records = False

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

def resolve_session_file(session_arg, wait=False):
    # A direct path wins.
    candidate = Path(session_arg)
    if candidate.is_file():
        return candidate
    # Otherwise treat the argument as a session id or a unique id prefix.  With
    # WAIT (used when following a session tincan just started with
    # --session-id), the .jsonl does not exist until Claude's first turn, so
    # poll for it to appear instead of failing.
    while True:
        matches = [path for path in iter_session_files()
                   if path.stem == session_arg or path.stem.startswith(session_arg)]
        exact = [path for path in matches if path.stem == session_arg]
        if exact:
            return exact[0]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            die("Ambiguous session prefix {!r}; matches:\n{}".format(
                session_arg, "\n".join(path.stem for path in matches)))
        # No matches yet.
        if not wait:
            die("No session matching {!r} found under {}".format(
                session_arg, get_projects_root()))
        time.sleep(POLL_INTERVAL_SECONDS)

# * Session id generation
def print_new_session_id():
    # Print a fresh UUID for `claude --session-id <uuid>'.  Generating it here
    # (Python's uuid4) keeps id generation in the component that already owns
    # session/file concerns and avoids depending on a system `uuidgen'.
    print(uuid.uuid4())

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

def format_marker_time(timestamp):
    # A readable, space-separated form of a record's ISO-8601 TIMESTAMP,
    # "YYYY-MM-DD HH:MM:SS" in local time, appended to "@@@" marker lines so the
    # transcript (and the Emacs view) show when each block was recorded.  Empty
    # when the timestamp is missing or unparseable.
    if not timestamp:
        return ""
    try:
        parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        return ""
    return parsed.astimezone().strftime("%Y-%m-%d %H:%M:%S")

def format_block(header, body, lang=None, timestamp=None):
    body = body.strip("\n")
    if not body.strip():
        # Skip empty blocks (e.g. thinking whose text was not persisted).
        return None
    # LANG=None means render the body as-is; any string fences it (the empty
    # string makes a plain, language-less code block).
    if lang is not None:
        body = fence_body(body, lang)
    stamp = format_marker_time(timestamp)
    if stamp:
        header = header + " " + stamp
    return header + "\n" + body + "\n\n"

def get_content(record):
    message = record.get("message")
    if isinstance(message, dict):
        return message.get("content")
    return None

# ** Tool blocks
# Map a file extension to a Markdown code-fence language so the Emacs side can
# fontify it natively; an unknown extension yields a plain, language-less fence.
EXT_TO_LANG = {
    ".py": "python", ".el": "emacs-lisp",
    ".js": "js", ".jsx": "js", ".mjs": "js", ".cjs": "js",
    ".ts": "typescript", ".tsx": "typescript",
    ".json": "json", ".md": "markdown", ".markdown": "markdown", ".org": "org",
    ".sh": "sh", ".bash": "sh", ".zsh": "sh",
    ".c": "c", ".h": "c",
    ".cc": "c++", ".cpp": "c++", ".cxx": "c++", ".hpp": "c++", ".hh": "c++",
    ".rb": "ruby", ".rs": "rust", ".go": "go", ".java": "java", ".kt": "kotlin",
    ".html": "html", ".htm": "html", ".css": "css", ".scss": "scss",
    ".yaml": "yaml", ".yml": "yaml", ".toml": "toml", ".sql": "sql",
    ".lua": "lua", ".php": "php", ".pl": "perl", ".pm": "perl",
    ".clj": "clojure", ".scm": "scheme", ".rkt": "racket", ".hs": "haskell",
    ".tex": "latex", ".xml": "xml",
}

def lang_for_path(path):
    if not path:
        return ""
    return EXT_TO_LANG.get(Path(path).suffix.lower(), "")

def marker_text(value, default=""):
    # A model-written JSON field rendered onto a marker line, or DEFAULT when it
    # is not a plain single-line string.  Nothing guarantees a tool_use field's
    # type or content: a number raises on concatenation, a list is not even
    # hashable for a dict lookup, and an embedded newline forges a second line -
    # one beginning with "@@@" would fake a section marker and split the block in
    # the view.  This matters more than a malformed record deserves, because
    # `handle_line' guards only against JSON errors (D10): an exception raised
    # while rendering escapes it and kills the follower mid-session.
    if not isinstance(value, str) or "\n" in value:
        return default
    return value

# Line beginnings that carry structure in the rendered transcript: a body line
# starting with one of these would fake a section marker, open a code fence that
# swallows everything after it, or forge a Markdown heading.
UNSAFE_LINE_PREFIXES = ("@@@", "```", "~~~", "#")

def body_line(value):
    # A model-written field rendered as one plain line inside a block's body, or
    # "" when it cannot be.  Whitespace is collapsed, newlines included, so the
    # value cannot forge a second line, and a structural beginning disqualifies
    # it: the text is a caption, and no caption is worth the rest of the block.
    if not isinstance(value, str):
        return ""
    collapsed = " ".join(value.split())
    if collapsed.startswith(UNSAFE_LINE_PREFIXES):
        return ""
    return collapsed

# Tools whose input is dominated by file content: render that content as a code
# block (in the file's language) instead of escaped JSON.  Maps tool name to the
# input fields holding the path and the content.
CONTENT_TOOLS = {
    "Write": ("file_path", "content"),
}

# "Edit" replaces one snippet of a file with another; the two snippets read far
# better as a unified diff than as escaped JSON strings, and a ```diff fence lets
# the Emacs side fontify them with `diff-mode' (D49).
def edit_diff(old_text, new_text):
    # Unified diff between an Edit's OLD_TEXT and NEW_TEXT as a list of lines,
    # empty when the two are equal.  Splitting on "\n" rather than with
    # str.splitlines() is a fidelity requirement, not a preference: splitlines()
    # also breaks on \v, \f, \x1c-\x1e, \x85, U+2028 and U+2029, and since the
    # body is rejoined with "\n" every one of those would be silently rewritten
    # into a real newline.  A form feed is an idiomatic page separator in Emacs
    # Lisp, and \x1e is tincan's own record separator (D47), so this is content
    # this project actually edits.  Splitting on "\n" is lossless, and its
    # trailing empty field additionally keeps a final newline visible, so an
    # edit that only adds or drops one still shows a difference.  The
    # "---"/"+++" pair difflib always leads with is dropped: the path is on the
    # marker line already, and without a file header diff-mode will not try to
    # refine the hunks against the file's current contents, which need not match
    # what the transcript recorded.
    old_lines = old_text.split("\n")
    new_lines = new_text.split("\n")
    # Context wide enough to span the longer side, so every line of both snippets
    # survives into the diff.  A normal diff elides context because it is still
    # on disk; these two snippets exist nowhere but this record, so eliding here
    # would delete them from the transcript (D49).  One hunk always results.
    context = max(len(old_lines), len(new_lines))
    lines = list(difflib.unified_diff(old_lines, new_lines, n=context, lineterm=""))
    return lines[2:]

def render_edit(tool_input, timestamp):
    # None when TOOL_INPUT is not a renderable Edit - malformed, or a no-op whose
    # diff would be empty - so the caller can fall back to the JSON rendering
    # rather than drop the block.
    old_text = tool_input.get("old_string")
    new_text = tool_input.get("new_string")
    if not isinstance(old_text, str) or not isinstance(new_text, str):
        return None
    lines = edit_diff(old_text, new_text)
    if not lines:
        return None
    path = marker_text(tool_input.get("file_path"))
    header = ROLE_TOOL_USE + " Edit"
    if path:
        header += " " + path
    if tool_input.get("replace_all"):
        # The one Edit input a diff of the two snippets cannot show, since it is
        # about the matches elsewhere in the file.
        header += " (replace_all)"
    return format_block(header, "\n".join(lines), lang="diff", timestamp=timestamp)

# ** Bash commands
# A "Bash" tool use is a command line, so it reads far better as a ```bash block
# (which the Emacs side fontifies with `sh-mode') than as a JSON string, with the
# model's own one-line description as a caption under it (D55).
# When `shfmt' is on PATH the command is pretty-printed first (D56): a real shell
# parser, so a `;'-chained one-liner comes out as one command per line - indented
# when the list is inside `( )' - with heredoc bodies passed through untouched
# and no risk of rewriting what the command does.  Without it, or when it cannot
# parse the command, the command is shown exactly as it was run.  What shfmt
# leaves alone: it does no line wrapping, so a long pipeline stays on one line
# (the view soft-wraps it), and a compound command written on one line, such as
# `if ...; then ...; fi' or an `&&' chain, keeps that form.
SHFMT_COMMAND = ("shfmt", "--language-dialect", "bash", "--indent", "2",
                 "--binary-next-line", "--case-indent")
SHFMT_TIMEOUT_SECONDS = 5
# Formatting can only ever change a command holding more than one statement, so
# anything simpler skips the subprocess: printing a transcript spawns shfmt once
# per command that stands to gain from it, not once per Bash call.
SHFMT_TRIGGERS = (";", "\n")
format_commands = True
shfmt_program = None

def shfmt_available():
    # Whether shfmt is installed, looked up once and remembered.
    global shfmt_program
    if shfmt_program is None:
        shfmt_program = shutil.which(SHFMT_COMMAND[0]) or ""
    return bool(shfmt_program)

def format_command(command):
    # COMMAND pretty-printed, or COMMAND unchanged when it cannot be or would not
    # gain from it.  Every failure path returns the original: a tidier command is
    # a nicety, and a missing, broken or slow formatter must not cost a record
    # its rendering (nor, in --follow, stall the stream behind it).
    if not format_commands:
        return command
    if not any(trigger in command for trigger in SHFMT_TRIGGERS):
        return command
    if not shfmt_available():
        return command
    try:
        completed = subprocess.run(SHFMT_COMMAND, input=command,
                                   capture_output=True, text=True,
                                   encoding="utf-8", errors="replace",
                                   timeout=SHFMT_TIMEOUT_SECONDS)
    except (OSError, subprocess.SubprocessError):
        return command
    if completed.returncode != 0:
        return command
    formatted = completed.stdout.strip("\n")
    if not formatted.strip():
        return command
    return formatted

# The Bash inputs this rendering accounts for.  A record carrying any other field
# falls back to the JSON body, so an input tincan does not know about is never
# dropped silently - the same rule the Edit and content-tool paths follow.
BASH_FIELDS = frozenset(("command", "description", "timeout",
                         "run_in_background", "dangerouslyDisableSandbox"))

def bash_marker_notes(tool_input):
    # The Bash inputs that are not the command itself, as short marker-line
    # notes: they say how the command was run rather than what it was, so inside
    # the ```bash block they would read as part of the command.
    notes = []
    if tool_input.get("run_in_background"):
        notes.append("background")
    if tool_input.get("dangerouslyDisableSandbox"):
        notes.append("no sandbox")
    timeout = tool_input.get("timeout")
    # A bool is an int in Python, and "timeout true" is not a timeout.
    if isinstance(timeout, (int, float)) and not isinstance(timeout, bool):
        # Claude Code counts this one in milliseconds.
        notes.append("timeout {:g}s".format(timeout / 1000))
    return notes

def render_bash(tool_input, timestamp):
    # None when TOOL_INPUT is not a renderable Bash use - no command, or a field
    # this does not account for - so the caller can fall back to the JSON
    # rendering rather than drop the block.
    command = tool_input.get("command")
    if not isinstance(command, str) or not command.strip():
        return None
    if not set(tool_input).issubset(BASH_FIELDS):
        return None
    header = ROLE_TOOL_USE + " Bash"
    notes = bash_marker_notes(tool_input)
    if notes:
        header += " (" + ", ".join(notes) + ")"
    body = fence_body(format_command(command).strip("\n"), "bash")
    description = body_line(tool_input.get("description"))
    if description:
        body += "\n" + description
    # The body is fenced already: the description has to stay outside the fence.
    return format_block(header, body, timestamp=timestamp)

# ** Tool use dispatch, and tool results
def render_tool_use(block, timestamp):
    # Sanitize the name before it is used, since it both lands on the marker line
    # and keys a dict lookup that an unhashable value would break.
    name = marker_text(block.get("name"), "?")
    tool_input = block.get("input")
    if name == "Edit" and isinstance(tool_input, dict):
        rendered = render_edit(tool_input, timestamp)
        if rendered:
            return rendered
    if name == "Bash" and isinstance(tool_input, dict):
        rendered = render_bash(tool_input, timestamp)
        if rendered:
            return rendered
    spec = CONTENT_TOOLS.get(name)
    if spec and isinstance(tool_input, dict):
        path_field, content_field = spec
        content = tool_input.get(content_field)
        # A non-string content is a malformed record: fall through to JSON, which
        # renders it losslessly, rather than raise inside `format_block'.  Same
        # fallback a malformed Edit takes, so no block is ever lost to one.
        if isinstance(content, str):
            # Render the file content as a fenced code block, with the path on
            # the marker line and the language taken from the file extension.
            path = marker_text(tool_input.get(path_field))
            header = ROLE_TOOL_USE + " " + name
            if path:
                header += " " + path
            return format_block(header, content, lang=lang_for_path(path),
                                timestamp=timestamp)
    # Default: pretty-print the input as JSON.
    if tool_input is None:
        body = ""
    else:
        body = json.dumps(tool_input, indent=2, ensure_ascii=False)
    return format_block(ROLE_TOOL_USE + " " + name, body, lang="json", timestamp=timestamp)

def maybe_prettify_json(text):
    # If TEXT is a JSON object or array, return (pretty-printed, "json"); else
    # (TEXT, "").  Only objects/arrays are reformatted - a bare string or number
    # that happens to parse as JSON is left verbatim (it is just text).
    stripped = text.strip()
    if not stripped or stripped[0] not in "{[":
        return text, ""
    try:
        parsed = json.loads(stripped)
    except ValueError:
        return text, ""
    if isinstance(parsed, (dict, list)):
        return json.dumps(parsed, indent=2, ensure_ascii=False), "json"
    return text, ""

def render_tool_result(block, timestamp):
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
    # Pretty-print JSON results (fenced as json); leave plain text verbatim.
    body, lang = maybe_prettify_json(body)
    return format_block(header, body, lang=lang, timestamp=timestamp)

# ** User and assistant records
def render_user_block(block, timestamp):
    block_type = block.get("type") if isinstance(block, dict) else None
    if block_type == "text":
        return format_block(ROLE_USER, block.get("text", ""), timestamp=timestamp)
    if block_type == "tool_result":
        # Tool results are delivered to the model as a "user" message (API shape).
        return render_tool_result(block, timestamp)
    return None

def render_user(record):
    timestamp = record.get("timestamp")
    content = get_content(record)
    parts = []
    if isinstance(content, str):
        rendered = format_block(ROLE_USER, content, timestamp=timestamp)
        if rendered:
            parts.append(rendered)
    elif isinstance(content, list):
        for block in content:
            rendered = render_user_block(block, timestamp)
            if rendered:
                parts.append(rendered)
    return "".join(parts) if parts else None

def render_assistant_block(block, timestamp):
    block_type = block.get("type") if isinstance(block, dict) else None
    if block_type == "text":
        return format_block(ROLE_ASSISTANT, block.get("text", ""), timestamp=timestamp)
    if block_type == "thinking":
        return format_block(ROLE_THINKING, block.get("thinking", ""), timestamp=timestamp)
    if block_type == "tool_use":
        return render_tool_use(block, timestamp)
    return None

def render_assistant(record):
    timestamp = record.get("timestamp")
    content = get_content(record)
    parts = []
    if isinstance(content, str):
        rendered = format_block(ROLE_ASSISTANT, content, timestamp=timestamp)
        if rendered:
            parts.append(rendered)
    elif isinstance(content, list):
        for block in content:
            rendered = render_assistant_block(block, timestamp)
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
        header = "{} ({}s)".format(ROLE_DONE, seconds)
        stamp = format_marker_time(record.get("timestamp"))
        if stamp:
            header += " " + stamp
        return header + "\n\n"
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
        if frame_records:
            # Strip stray separators from content so the framing stays sound.
            text = text.replace(RECORD_SEPARATOR, "") + RECORD_SEPARATOR
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
            # Keep the latest timestamp seen (records are appended in order), so
            # this is the time of most recent activity, not session creation. It
            # is both the picker's date column and its sort key.
            if record.get("timestamp"):
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

def within_days(timestamp, days):
    # True if TIMESTAMP (the session's most recent activity) is within DAYS days
    # of now.  DAYS None means no limit; an undatable session is kept rather than
    # silently hidden.
    if days is None or not timestamp:
        return True
    try:
        parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        return True
    return parsed >= datetime.now(timezone.utc) - timedelta(days=days)

def show_sessions(show_all=False, days=None):
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
    if days is not None:
        selected = [m for m in selected if within_days(m["timestamp"], days)]
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
        "--wait", action="store_true",
        help="with --follow, wait for the transcript to appear instead of failing"
             " (for a just-started session whose file is not written yet)")
    parser.add_argument(
        "--new-session-id", action="store_true",
        help="print a fresh UUID (for claude --session-id) and exit")
    parser.add_argument(
        "--show-sessions", action="store_true",
        help="list sessions (id, timestamp, title, cwd) and exit")
    parser.add_argument(
        "--all", action="store_true",
        help="with --show-sessions, list every project's sessions, not just here")
    parser.add_argument(
        "--days", type=int, metavar="N",
        help="with --show-sessions, keep only sessions active within the last N days")
    parser.add_argument(
        "--no-shfmt", action="store_true",
        help="show Bash commands exactly as they were run, instead of"
             " pretty-printing them with shfmt when it is installed")
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
    if args.new_session_id:
        print_new_session_id()
        return
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
        show_sessions(args.all, args.days)
        return
    if not args.session:
        parser.error("a session id is required (or use --show-sessions)")
    if args.no_shfmt:
        global format_commands
        format_commands = False
    path = resolve_session_file(args.session, wait=args.wait and args.follow)
    if args.follow:
        global frame_records
        frame_records = True
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
