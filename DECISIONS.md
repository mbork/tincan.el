# Decisions

This file records non-obvious design decisions made while implementing tincan,
together with the reasoning behind them, so that any decision can be revisited
or reverted in isolation.  Each entry notes the commit theme it belongs to.

## Python transcript script

### D1 - Language and dependencies
Python 3, standard library only, no third-party dependencies.
Rationale: KISS MVP; the script only reads JSONL files and writes text.

### D2 - Script filename: `tincan.py`
Originally `tincan-tail.py`, renamed to `tincan.py` once it outgrew tailing:
it now also lists sessions, runs the Notification hook, and installs/removes/
checks it.  `tincan.py` is the single Python entry point, sitting alongside
`tincan.el`.  Note the installed hook command embeds this file's absolute path
(from `realpath(__file__)`), so a rename requires re-pointing any installed
hook (re-run `--install-hook`, or edit the settings file).

### D3 - Session resolution
The positional argument may be: a path to a `.jsonl` file, a full session id,
or a unique session-id prefix.  Non-path arguments are resolved by globbing
`~/.claude/projects/*/*.jsonl` across *all* projects.
Rationale: session ids are UUIDs and globally unique, so this avoids having to
reconstruct Claude Code's fragile encoding of the working directory into the
project directory name.  An exact stem match wins; an ambiguous prefix is an
error.

### D4 - Config directory discovery
Honor `CLAUDE_CONFIG_DIR` if set, otherwise use `~/.claude`.
Rationale: matches Claude Code's own behavior and keeps the script robust.

### D5 - Which records are rendered
Only `user` and `assistant` records are rendered.  Bookkeeping records
(`mode`, `permission-mode`, `system`, `attachment`, `file-history-snapshot`,
`ai-title`, `last-prompt`, ...) are skipped in the MVP.
Rationale: they are not part of the human-readable conversation.

### D6 - Section markers: `@@@ ROLE`
Each rendered block is introduced by a line of the form `@@@ USER`,
`@@@ ASSISTANT`, `@@@ THINKING`, `@@@ TOOL_USE <name>`, `@@@ TOOL_RESULT`.
Rationale: `@@@` at the beginning of a line is rare in prose, code, and tool
output, so the Emacs side can font-lock reliably.  The markers live in
constants and are trivially changeable.

### D7 - Block body rendering
Tool-use inputs are rendered as pretty-printed JSON (`indent=2`).  Tool results
are rendered verbatim, with no truncation in the MVP.
Rationale: generic and lossless; the Emacs side can prettify later if wanted.

### D8 - Skip blank blocks
A block whose body is empty/whitespace produces no output (no bare header).
Rationale: thinking text is often not persisted to the transcript (only a
signature is kept), which would otherwise yield empty `@@@ THINKING` headers.

### D9 - Output discipline
The only thing written to stdout is transcript text, flushed after every write.
All diagnostics go to stderr.  `BrokenPipeError` (downstream reader closed) and
`KeyboardInterrupt` exit quietly.
Rationale: a downstream `tail -f`/`auto-revert-tail-mode` must see a clean,
append-only stream.

### D10 - Follow mode
`--follow`/`-f` drains the file, then polls every 0.25 s using a plain read
offset.  Only newline-terminated lines are processed, so a half-written record
is never parsed; `handle_line` additionally swallows JSON errors.
We assume session files are append-only (Claude Code never truncates or
rewrites them), so there is no rotation/truncation handling.
Rationale: KISS resilience without inotify or extra dependencies; the newline
rule is what actually guarantees we never parse incomplete JSON.  Speculative
truncation handling was removed because it cannot occur in practice and a
half-correct version (it missed in-place larger rewrites) is worse than none.

### D11 - `--show-sessions` (deepest-ancestor by default; `--all` for everything)
By default lists the sessions of the *closest* launch directory at or above the
working directory: among sessions whose `cwd' is an ancestor-or-equal of the cwd
(component-aware via `os.path.commonpath', so `M-x tincan' works from any
subproject directory), the ones with the deepest such `cwd'.  `--all' instead
lists every project's sessions.  Output is tab-separated
`id<TAB>timestamp<TAB>title<TAB>cwd', one per line, most recently active first.
The title is `customTitle' (a `/rename'), else `aiTitle', else the first user
prompt (collapsed/truncated), else the id (see D27).  The timestamp is the
session's most recent activity - the last record's timestamp, not the first
(creation) one - in local time as ISO-8601 with offset; it is both the shown
date and the sort key, so the newest-active session sorts to the top (which is
what `tincan-dwim' resumes).
Rationale: exact-cwd matching broke when run below the project root; ancestor
matching is symlink-safe for free because both `os.getcwd()' and the recorded
`cwd' are physical paths.  The `cwd' column lets the Emacs all-projects picker
narrow by directory.  Each file is fully scanned because `aiTitle'/`customTitle'
can appear late; acceptable for the expected handful of sessions.

## Emacs view mode

### D12 - Single `tincan.el` with the standard package skeleton
All Emacs code lives in one `tincan.el` (header, Commentary, Code, footer).
Outli sections use `;; *` / `;; **` within the Code section; the conventional
`;;; Commentary:` / `;;; Code:` lines do not clash with that pattern.
Rationale: KISS for a small package; the view mode, future input mode, and
orchestration command are all small and naturally cohabit one file.

### D13 - `tincan-view-mode` derives from `special-mode`
Rationale: it is a read-only viewer, and `special-mode` provides read-only
buffers plus convenient keys (q, g, SPC, n/p).  It stays compatible with
`auto-revert-tail-mode`, which binds `inhibit-read-only` when appending, so the
buffer can still follow the growing transcript.  The mode handles display only;
launching the tail and turning on auto-revert is the orchestration's job.

### D14 - Font-lock only the `@@@ ROLE` marker lines
Five customizable faces (`tincan-user`, `tincan-assistant`, `tincan-thinking`,
`tincan-tool-use`, `tincan-tool-result`) inherit from theme font-lock faces and
are applied to the whole marker line; `font-lock-defaults` is keywords-only (no
syntactic fontification).  Block bodies are not fontified in the MVP.
Rationale: matches the "very simple" brief, looks reasonable in any theme, and
keeps the marker contract with tincan.py explicit in one `defvar`.

### D16 - Markdown rendering via a runtime dispatcher
Transcript bodies are Markdown (Claude's output), so `tincan-render-buffer`
activates a Markdown major mode when available and layers the `@@@ ROLE` markers
on top with `font-lock-add-keywords`; the marker keywords carry the OVERRIDE
flag so they always win over Markdown's own fontification.  `tincan-view-mode`
(from D13) becomes the plain fallback used when no Markdown mode is available.
Mode choice is controlled by `tincan-markdown-mode` (t = auto-detect
`gfm-mode`/`markdown-mode`; nil = disabled; a function symbol = that mode, e.g.
`gfm-view-mode`).  The buffer is forced read-only in every case.
Rationale: a runtime dispatcher (rather than `define-derived-mode` with a
Markdown parent) is needed because `define-derived-mode` fixes its parent at
macro-expansion time, which byte-compilation would freeze to whatever was
available when compiled - the wrong choice if Markdown is installed later.
Auto-detection prefers the editing modes (markup visible, fontified) over the
view modes so exact code/markup stays readable in a transcript; users who want
the rendered look can set `tincan-markdown-mode` to `gfm-view-mode`.

### D17 - Native code-block fontification on by default
When a Markdown mode is used, `tincan-render-buffer` sets
`markdown-fontify-code-blocks-natively' buffer-locally so fenced code blocks are
highlighted with each language's own major mode.  This is gated by the
`tincan-fontify-code-blocks-natively' defcustom (default t).
Rationale: agentic-coding transcripts are code-heavy, so per-language
highlighting is worth a lot; the opt-out exists because native fontification
loads language major modes, which can add overhead on a large, continuously
tailed buffer.

## Revisited decisions

### D15 - Polling, not inotify, for follow mode (revisits D10)
Follow mode keeps the 0.25 s polling loop instead of switching to inotify.
inotify would only replace the wait step (the offset tracking, the
newline-complete-line rule, and the JSON resilience are all independent of how
we wait), so it changes little of substance, while it costs:
- A dependency: Python's stdlib has no inotify module, so it means a new
  dependency (`inotify_simple`/`pyinotify`/`watchdog`) or ~30-40 lines of
  `ctypes` against libc.
- Portability: inotify is Linux-only, so it would not replace polling but add a
  Linux-only fast path that still needs the polling loop as a fallback.
- Extra edge cases: a setup race (must drain to EOF after arming the watch,
  with a timeout as a safety net) and, for full robustness, watching the
  directory rather than the file inode.
The benefit is marginal: at most ~250 ms less latency and a few trivial reads
per second saved on an idle, human-facing viewer.
If latency ever feels laggy, the cheap first move is lowering
`POLL_INTERVAL_SECONDS` (e.g. to 0.1) - portable, one line, no deps.
Reserve inotify for the case where profiling shows polling is a real problem,
which for a transcript viewer it should not be.

### D18 - Fence TOOL_USE and TOOL_RESULT bodies (extends D7)
TOOL_USE bodies are wrapped in a ```json fenced code block and TOOL_RESULT
bodies in a plain (language-less) fence, so a Markdown view renders them as
code (and, with D17, highlights the JSON natively).  `format_block` grew a
`lang` argument: `None` renders the body as-is (USER/ASSISTANT/THINKING stay
prose Markdown), any string fences it.  The fence length is one backtick longer
than the longest backtick run inside the body (minimum three), per the
CommonMark rule, so embedded backticks/fences cannot close the block early.
Tool-result errors are flagged on the marker line (`@@@ TOOL_RESULT (error)`)
rather than inside the fenced body, keeping the body verbatim.
Rationale: tool I/O is data/code, not prose, so it should be monospaced and not
interpreted as Markdown; only these two block kinds are fenced because the
others are genuinely prose.

### D19 - Render turn_duration as `@@@ DONE`, for transcript-based completion
A `system` record with `subtype: turn_duration` is rendered as a standalone
`@@@ DONE (Ns)` marker (seconds rounded from `durationMs`); the Emacs side adds
a matching `tincan-done` face.  This is also the planned signal for detecting
that the agent has finished a turn, in place of Claude Code Stop hooks.
The transcript carries `turn_duration` exactly once at the true end of each
turn, immediately after the final `assistant` message - strictly better than
`stop_reason: end_turn`, which can occur twice within one turn.  Detecting
completion from the transcript reuses the single channel the follower already
streams, so no `settings.json` hook setup is needed.
Known limitations (to be covered later): abnormal endings (interrupt, crash,
API error) emit no `turn_duration`, so a manual escape hatch
(`tincan-unblock-agent-manually`) will be provided; and a mid-turn pause for a
permission prompt looks like "working" (no `turn_duration` yet), which is the
one case a `Notification` hook would handle better - it can be added narrowly
if it proves annoying.
The literal TUI string ("Cooked for Ns", with a randomized verb) is not stored
in the transcript and is deliberately not reproduced; only the duration is.

### D20 - Optional Notification hook via a status file (addresses D19's gap)
The "Claude is waiting for your input" state (tool-permission prompt or idle)
is the one case the transcript cannot express (D19), so it is covered by an
*optional* Claude Code `Notification` hook.  The hook is
`tincan.py --notification-hook`: it reads the event JSON on stdin and
writes the message to a small per-session file at
`<config-dir>/tincan/<session-id>.notify`.  A file, deliberately, not
`emacsclient`, so the producer stays a plain stdin-to-file script with no Emacs
coupling.
Installation lives in the Python script too: `--install-hook`,
`--uninstall-hook`, `--check-hook` (the last exits 0/1), with an optional
`--settings-file`.  The default target is `.claude/settings.local.json`
resolved against the working directory - Claude Code's personal, gitignored
project settings - so the hook fires only for the project you drive with tincan
and is never committed; install from where you start Claude Code, or pass
`--settings-file`.  They load the JSON,
back it up to `.bak`, merge in (or remove) our hook, prune empty containers, and
write it back with `json.dumps(indent=2)`.  Emacs only provides thin wrappers
(`tincan-install-hook`, `tincan-uninstall-hook`, `tincan-hook-installed-p`) that
`call-process` the script and surface its output/exit code.
Rationale - why Python owns the editing, not Emacs: the hook command string and
all paths already live in Python, and the script can self-reference its own
absolute path (`os.path.realpath(__file__)`), so what gets installed provably
matches what `--check-hook`/`--uninstall-hook` look for - no cross-language
duplication that could drift.  It also keeps one JSON implementation instead of
two (the elisp `alist`/vector round-trip is fiddly) and makes the hook
installable without Emacs.  The only cost is Emacs shelling out and reading an
exit code, which is trivial.
Caveats: it does NOT do tool selection - it only signals "Claude wants you",
which you still handle in the terminal.  The installed command is
`python3 <script>` (portable, no executable-bit dependency).  After install,
Claude Code must be restarted or `/hooks` run so it reviews and loads the change
(its hook-safety mechanism); the round-trip also reformats the settings file,
hence the backup.

### D21 - Read-only orchestration via a process filter
`M-x tincan' picks a session (from `tincan.py --show-sessions', parsed from
its tab-separated output via `completing-read') and watches it live: it runs
`tincan.py <id> --follow' as an async `make-process' whose filter feeds the
output into a rendered, read-only buffer.
Chosen over streaming to a temp file + `auto-revert-tail-mode' because the
filter is event-driven (no temp file, no second polling layer on top of the
follower's own poll) and the same function that inserts text is the natural
place to react to in-stream markers like `@@@ DONE'.  The cost is handling
chunked output ourselves: process output arrives in arbitrary chunks, and a line
(or even a searched string) can be split across calls.  The filter therefore
uses the marker idiom (see [[process-filter-idiom]]): insert each chunk at the
`process-mark', and act only on newline-terminated lines - the same discipline
tincan.py uses on the file side, mirrored with a marker instead of a byte
offset.
Session selection runs in `default-directory' (that is the cwd
`--show-sessions' filters by), so invoke `tincan' from the project root; the
follower itself resolves the session by id regardless of cwd.  The buffer reuses
a live watcher, follows the tail only in windows already at the end, and kills
the follower from `kill-buffer-hook'.
The agent state is shown in the mode line: `working'/`idle' is derived from the
stream (a `@@@ DONE' line means idle), and `needs-input' is driven by a
`file-notify' watch on the `.notify' *directory* (the file may not exist yet, so
we watch the directory and match the basename), cleared back to `working'/`idle'
when transcript activity resumes.  The watch is best-effort: if the optional hook
(D20) is not installed or watching is unsupported, only working/idle show.

### D22 - Foldable `@@@` sections, folded by default except USER/ASSISTANT
The viewer folds with `outline-minor-mode'.  `outline-regexp' matches both `@@@ '
section markers and Markdown `#' headings, and `tincan--outline-level' makes the
`@@@' sections level 1 with Markdown headings nested below - so TAB folds either
a section or a heading within it.  Markdown headings deliberately go through
`outline-cycle' (not Markdown's `markdown-cycle'): `markdown-cycle' navigates via
`outline-regexp'/`outline-level', which we have repurposed, so it would jump to
the wrong place and error (`markdown-end-of-subtree' on a nil position).  The
trade-off is that a `#'-prefixed line inside a code block also looks like a
heading, which is harmless (it just becomes foldable).
`outline-minor-mode-cycle' (Emacs 28.1+) binds TAB on a heading to
`outline-cycle' and S-TAB to `outline-cycle-buffer'.  This wins over the major
mode's TAB on headings because outline installs the binding on the heading via
an overlay keymap (higher precedence than the major-mode map).  It works in GUI
too: `markdown-mode' binds TAB as `[9]' (not `<tab>'), so a GUI `<tab>' with no
binding is translated to `[9]' and lands on `outline-cycle' on a heading.
Every section whose role is not in
`tincan-unfolded-sections' (default `("USER" "ASSISTANT")') starts folded,
keeping thinking/tool calls/tool results/DONE out of the way.
Folding is overlay-based, so it works in the read-only buffer with no
`inhibit-read-only'.  `tincan--autofold' only folds sections it has not passed
(tracked by `tincan--fold-marker', the same idiom as the scan marker) and never
folds the still-arriving last section, so streaming folds new sections exactly
once and never re-folds one the user manually opened.
`outline-minor-mode-cycle' cycles only on the heading line; to fold from within
a section's body too, the view map binds both `TAB' and `<tab>' to
`tincan-cycle', which goes back to the enclosing heading and calls
`outline-cycle'.  On a heading the heading-local cycle map still wins (that path
is unchanged); elsewhere `tincan-cycle' runs, which also shadows `markdown-cycle'
off-heading - avoiding its misnavigation on the non-Markdown `outline-regexp'.
Binding `<tab>' as well as `TAB' is what makes the body case win over the
major mode's own `<tab>' in a GUI.  (See D23 for the Emacs floor folding relies
on.)

### D23 - Emacs 30.1 floor
`Package-Requires' is `((emacs "30.1"))'.  The folding (D22) relies on
`outline-minor-mode-cycle' (Emacs 28.1+); nothing else in the file needs to run
on older Emacs.
Rationale: a personal tool run on current Emacs - no reason to carry a lower
floor, and the folding is simpler for leaning on the built-in cycle keys.

### D27 - Session title: prefer the renamed title; use it in the buffer name
`read_session_meta' prefers `customTitle' (written by `/rename') over `aiTitle'
(auto-generated), then the first user prompt, then the session id.  Each kind is
optional and every combination occurs in practice (some sessions have neither
title; one can have a custom title but no AI title), so it is a graceful
fallback chain.  Both of a session's buffers carry the same label
(`tincan--buffer-label'): the view is `*tincan view: <title>*' and the terminal
`*tincan terminal: <title>*', with the title abbreviated to
`tincan-buffer-title-width' columns (default 16; short id when there is no
title).  The terminal used to be named after its launch directory's full path,
which was long and not per-session (several sessions can share a project dir);
the title is short and pairs the two buffers so they sort together and one
string narrows to both in `C-x b'.
Because the title can change mid-session (a later `/rename'), buffer reuse is
keyed on the session id held buffer-locally, not on the buffer name - so
re-watching a renamed session reuses its buffer instead of spawning a duplicate
(`generate-new-buffer' names only genuinely new ones).  A new session's buffers
start as the short id (no title yet); `tincan-rename' re-reads the transcript
title and renames the view and the terminal together to catch up a `/rename'.

### D28 - `M-x tincan' session picking: deepest-ancestor, `C-u' for all
`M-x tincan' lists this project's sessions (D11's deepest-ancestor match), so it
works from any subdirectory.  With a prefix argument (`C-u') it offers *every*
project's session instead - the escape hatch for "I am not in the project" or
"I want another project's session".
For the all-projects picker the candidate string is \"TITLE  DIR\" (abbreviated
directory), because completion backends match input against the candidate
*string*: putting both title and directory there lets you narrow by either in
vanilla `completing-read', Vertico, Ivy or Helm alike (annotations are display
only and are not matched).  How flexibly a mid-string field narrows depends on
`completion-styles' (Ivy/Helm and orderless do it out of the box; vanilla wants
`flex'/`substring'), which is the user's config, not tincan's concern.
Chosen over detecting a project "root" (vc/project.el/dominating file) because
those are heuristics that can disagree with the directory Claude actually
launched in, whereas the ancestor match reads the real recorded `cwd'.

These decisions record the chosen shape of sending textual replies back to
Claude Code (the input mode).  D24-D30 are the early design; D31-D38 are the
final, implemented design, which revises several of them now that the `claude'
CLI's `--session-id'/`--resume' flags let tincan own the session id.

### D24 - No tmux: run Claude in an Emacs terminal buffer
Claude is launched directly in an Emacs terminal-emulator buffer (see D26), not
inside tmux.  Replies are sent to that buffer's process, which is the send
target, so there is no session naming or pane discovery.
Rationale: simplicity over persistence, per the project's guiding principle.
The cost, accepted deliberately: no persistence/detach (killing the buffer or
Emacs ends the Claude session and loses an in-flight run) and no external-
terminal escape hatch for the TUI.  A kill confirmation is the only safeguard.

### D25 - Split "start Claude" from "attach a view" (REVISED by D31/D32)
Original rationale: a freshly started Claude session's transcript id is not known
until Claude writes the file, so auto-attaching at start is racy; making attach a
manual pick sidesteps the race and doubles as the escape hatch.
This is superseded: because tincan now owns the id (`--session-id' for new,
`--resume' for resume; D31) and the follower waits for the not-yet-written file
(`--wait'; D32), `tincan-start' auto-attaches in both directions with no race.
Manual `tincan-attach' survives only as an escape hatch / recovery, and it too is
deterministic - run from a terminal buffer, it (re)builds the view for *that
terminal's* stored id, so there is no session picking and no possible mislink.

### D26 - vterm when available, term as fallback
The terminal buffer uses `vterm' if it is available, else the built-in `term'.
Rationale: vterm renders Claude's full-screen TUI well; it is an optional,
feature-detected dependency (like markdown-mode), not a hard requirement, so the
no-new-dependencies rule holds.  `term' is the always-present fallback, with the
caveat that it renders a complex TUI less well and - with tmux dropped (D24) -
has no external-attach escape hatch.

### D29 - Input-mode design choices (early draft; see D31-D38 for the final form)
Most of these were superseded once tincan took ownership of the session id:
- Start vs attach (now D25/D31): `tincan-start' auto-attaches; manual attach is
  only an escape hatch.
- Reply safety (now D35): show the terminal on send *without stealing focus*,
  with a one-shot next-command dismissal, instead of "raise then bury".
- Keybindings (now D37): no global prefix; per-buffer maps with `C-c SPC' reply.
- Backend (still): the `vterm' path is implemented; `term' (D26) is deferred.
- No single "current session" (kept, now D33): no global `tincan--current-view';
  `tincan-reply' resolves its target from the current buffer.  Final mechanism in
  D33 - two origins (view, terminal), not three, since compose has its own send.

### D30 - Distinguishing the transcript view from the terminal
The view (rendered, read-only) and the vterm terminal show the same conversation
and are easy to confuse, especially in scrollback where the `@@@' markers scroll
out of sight.  Each buffer therefore carries an always-visible header line
identifying it (view: read-only transcript; terminal: type here).  A header line
is the strongest cue because it does not scroll (unlike the markers) and is more
prominent than the mode line; it is reinforced by distinct buffer-name prefixes
and the view's read-only-ness.  An optional `buffer-face-mode' background tint
(off by default) is scaffolded as an extra ambient cue - off because tints fight
themes and vterm's own colors.  Exact header-line contents are settled within the
implementing commit.

### D31 - tincan owns the session id (`--session-id` / `--resume`)
For a new session `tincan-start' generates a fresh UUID and launches
`claude --session-id <uuid>'; to resume, `C-u tincan-start' picks an existing
session and launches `claude --resume <id>'.  Either way tincan knows the id
before Claude finishes writing anything, which (a) removes the terminal<->session
pairing ambiguity entirely (the terminal buffer stores its own id), (b) lets the
view follow by id immediately, and (c) makes resume a single step.  The JSONL
filename equals the session id (verified against a real transcript), so
`--session-id <uuid>' yields `<uuid>.jsonl', which the follower finds by id.
The UUID comes from `tincan.py --new-session-id' (Python's `uuid4'), keeping id
generation in the component that already owns session/file concerns and avoiding
a dependency on a system `uuidgen'.
Rationale: without this, a vterm is an opaque pty - tincan cannot tell which
session a running `claude' uses (the id only surfaces as the file name), so any
attach would pair view and terminal by unverified user assertion, risking
"read one conversation, type into another".  Owning the id makes the pairing
correct by construction.

### D32 - Follower waits for a not-yet-written transcript (`--wait`)
A brand-new session has no `.jsonl' until Claude processes its first turn, so
following by id must tolerate an absent file.  `tincan.py --follow --wait' polls
for the file to appear (the same 0.25 s interval as follow mode) instead of
erroring, then follows normally.  `--wait' is opt-in: the standalone CLI still
errors fast on a typo'd id, while the Emacs follower always passes `--wait'
because it always has a genuine id.  This relocates the new-session race into one
polling loop in the follower rather than deferring attach (revises D25).

### D33 - Session-group linking via buffer-locals; reply resolves from buffer
There is deliberately no global "current session" - concurrent sessions are
supported - so each buffer in a group carries buffer-locals instead of a global
pointer.  The view holds `tincan--session-id', the follower `tincan--process',
`tincan--state', and `tincan--terminal' (its terminal buffer).  The terminal
holds `tincan--terminal-p', `tincan--session-id', and `tincan--view' (its view
buffer).  The compose buffer captures `tincan--terminal' and `tincan--view' when
spawned.  `tincan-reply' resolves its target from the current buffer: from the
view -> (view, view's terminal); from the terminal -> (terminal's view,
terminal).  Compose has its own send command, so the resolver handles two
origins, not three (this finalizes D29's und. mechanism).

### D34 - Reply gate and compose buffer
`tincan-reply' (run from the view or the terminal) only steers: when the view's
state is `needs-input' it surfaces the terminal so you answer the prompt there
(a pasted reply would be wrong during a permission prompt); otherwise it just
opens a compose buffer.  Composing is never blocked by Claude being busy - the
"still working, send anyway?" confirmation was moved to send time
(`tincan-compose-send'), so the check happens when it matters rather than
gating drafting (Claude queues mid-turn input anyway, so it is a soft guard).
The compose buffer uses a Markdown major mode when available
(markdown-ts-mode/gfm-mode/markdown-mode, else text-mode; the same
runtime-dispatch reasoning as D16) plus a `tincan-compose-minor-mode' binding
`C-c C-c' (send), `C-c C-k' (cancel) and `C-c C-z' (hide; D41).
Send pastes the text into the terminal with `vterm-send-string' (bracketed paste)
then `vterm-send-return', and kills the compose buffer.
Draft safety: a buffer-local `kill-buffer-query-functions' guard confirms
"Discard this draft?" before killing a compose buffer with a non-empty draft, so
cancel, `C-x k' and session close all ask first; a successful send bypasses it
(`tincan--compose-force-kill', since sending is not discarding).  `tincan-close'
closes the compose buffer first, so closing a session runs that same discard
confirmation and keeping the draft aborts the close.

### D35 - After sending, show the terminal without stealing focus
On send the terminal is shown for a misfire check, but focus stays on the view
(where Claude's reply streams, and where the sent USER message will also appear).
`tincan-show-terminal-on-send' selects how: `display' (default - show in a
window, do not select), `select' (raise and select), or `none'.  With `display',
and gated by `tincan-dismiss-terminal-on-next-command' (default t), a one-shot
`pre-command-hook' makes your next command in the view delete that popped
terminal window (the command still runs) - a momentary peek that clears the
instant you move on, with no timer.  `tincan-delete-terminal-window' (`C-c 0')
dismisses the terminal window on demand at any other time.
Rationale: a timed auto-bury steals focus unpredictably and bakes in a magic
number; decoupling "visible" from "selected" achieves "glance, then keep reading"
without either problem.

### D36 - Distinct names and header lines for the three buffers (extends D30)
The buffers are named distinctly: view `*tincan view: TITLE*', terminal
`*tincan terminal: DIR*' (no title exists at start, so the abbreviated directory
is the stable identity), compose `*tincan compose: TITLE*'.  Each carries an
identifying header line (view: read-only transcript; terminal: type here;
compose: send/cancel keys).  Agent state (`[working]'/`[idle]'/`[needs input]')
is shown in both the view's header line and its mode line via one shared
formatter so the two cannot drift.  The new-session terminal's header line also
carries a transient hint (give the session a title; the already-open view follows
in the background; kill + restart as an escape hatch) until the first turn lands.

### D37 - Keybindings: no global binding, per-buffer maps
Entry commands (`tincan-view', `tincan-start', `tincan-attach') are M-x only;
tincan binds no global keys (bind them yourself if wanted).  In-session keys live
in buffer-local maps.  View and terminal share `C-c SPC' (reply), `C-c o' (go to
the sibling buffer), and `C-c k' (close the session).  The view adds `C-c 0'
(dismiss the terminal window) and, since it is read-only, single-key viewer
commands: `SPC'/`DEL' (page), `<'/`>' (ends), and three navigation tiers from
finest to coarsest - `n'/`p'/`u' the outline family (org/outline speed-key
style: every heading, @@@ marker or Markdown heading, `u' climbing to the
enclosing @@@ and a quiet no-op at the top), `M-n'/`M-p' (only @@@ section
markers, skipping Markdown headings; seldom needed, hence the modifier), and
`['/`]' (USER/ASSISTANT turns only, skipping thinking/tool) - all three skipping
sections hidden by `c' - plus `TAB' (fold the section at point, from its heading
or body; see D22), `c' (`tincan-conversation-only', hide non-conversation
sections; see D45), `/' (`isearch-forward', less/vim style), `q' (bury), `r'
(reply), `t' (terminal), `w' (copy the code block at point, else the section
body), `RET' (`find-file-at-point'), and `?' (`describe-mode').  Plain line
motion stays on `C-n'/`C-p' and the arrows.  Rationale: the two common motions
(heading and turn) get single keys and the rare one (all sections) the modifier,
matching observed use; `n'/`p'/`u' borrows outline speed-key habits.  The
terminal is a
`tincan-terminal-mode' minor mode layered over vterm (its lighter doubles as an
identity cue); it adds `C-c C-c' -> send a real interrupt to Claude, restored
because binding `C-c ...' keys makes `C-c' an Emacs prefix in the buffer.  It
also binds `C-z' to `ignore', because vterm would otherwise forward it as
SIGTSTP and suspend Claude with no job-control shell to resume it.  The
compose buffer uses `C-c C-c' (send) and `C-c C-k' (cancel).
Rationale: `C-c <letter>'/`C-c SPC' are the user keyspace, so they never clash
with markdown-mode; `C-c C-c'/`C-c C-k' is the familiar org-capture/magit idiom.

### D38 - markdown-ts-mode preferred when available (extends D16)
Auto-detection prefers `markdown-ts-mode' (Emacs 31, and only when the
tree-sitter `markdown' grammar is actually ready - `fboundp' alone is not enough)
over `gfm-mode' over plain `markdown-mode'.  `gfm-mode' beats `markdown-mode'
because Claude emits GitHub Flavored Markdown (fenced code with info strings,
tables, strikethrough, task lists, and intraword underscores left literal so
snake_case is not italicized).  The same detection feeds the view and the compose
buffer; the view falls back to `tincan-view-mode', compose to `text-mode'.  A
*view* mode (markup-hiding) is deliberately never the default, even on 31: a
code-heavy transcript wants the literal characters (D16).

### D39 - Render content-bearing tool uses as code, not JSON (extends D7/D18)
A `Write' tool_use is rendered as the file *content* in a fenced code block, with
the language inferred from the file extension and the file path appended to the
`@@@ TOOL_USE' marker line; an unknown extension yields a language-less fence.
This is driven by a `CONTENT_TOOLS' map (tool name -> path field, content field)
plus an `EXT_TO_LANG' map, so adding other single-content tools is a one-line
change.  All other tools keep the pretty-printed JSON rendering of D7/D18.
Rationale: a `Write''s input is dominated by the file body, which as JSON is
escaped, single-line-per-field and unreadable, and cannot be fontified by
language.  As a fenced code block it reads naturally and gets native per-language
fontification (D17) on the Emacs side, while the path on the marker line keeps
the font-lock/outline/state regexes intact (they match the marker prefix and
ignore trailing text).  The fence length still follows the CommonMark rule (D18),
so file content containing backticks widens the fence.
Not handled: `Edit'/`MultiEdit' carry two payloads (old/new string), so they do
not fit the single-content map and still render as JSON; a two-block renderer
could be added later.  (`Edit' since got one - a diff rather than two blocks;
see D49.  `MultiEdit' still renders as JSON.)
This renderer's path and content fields were later type-guarded along with the
Edit path's; see `marker_text' under D49.

### D40 - Session entry commands: start / resume / view / attach / dwim
The reply path got a clear front door and single-purpose verb commands, replacing
the earlier `tincan-start' that overloaded the prefix arg for new-vs-resume.
- `tincan-start' always starts a NEW session in `default-directory' (prefix arg
  ignored).
- `tincan-resume' resumes an existing session; the prefix widens the picker in
  notches (see Scope).  The resumed Claude always relaunches in the session's own
  recorded `cwd' - the prefix widens only the *list*, never the launch directory.
  Both the view and terminal buffers also get that `cwd' as their
  `default-directory', so commands run from either (find-file-at-point, etc.) act
  on the session's project, not wherever `tincan-resume' was invoked (which
  differs when resuming across projects with C-u C-u).
- `tincan-view' (read-only) is unchanged but shares the list format below.
- `tincan-attach' (escape hatch) is unchanged.
- `tincan' (alias of `tincan-dwim') is the front door: a 3-way DWIM, current
  project only.  In order: (1) a live tincan terminal for this project exists ->
  switch to it (its view if any); (2) else the project has a session on disk ->
  resume the latest; (3) else start a new one.
Scope has two axes - directory (this project, deepest-ancestor of
`default-directory' per D11, vs all projects) and a recency window
(`tincan-recent-days', default 7, vs all history).  Rather than cram both into
one prefix arg with a sign trick (assessed and rejected: unmemorable, and it left
"this project, all history" unreachable), the prefix widens in monotonic notches
- each `C-u' shows more (`tincan--resume-scope'):
  - none: this project, last N days
  - `C-u': this project, all history
  - `C-u C-u': all projects, last N days
  - `C-u C-u C-u' (or more/other): all projects, all history
`tincan-resume' and `tincan-view' share this; `tincan-start' ignores the prefix,
and `tincan' (dwim) is project-only by design (use `C-u C-u tincan-resume' to
cross projects).  The recency filter is the picker's alone: `tincan-dwim' calls
the list builder with no day limit, so "resume the latest" still finds a session
older than N days.  The filter is by most-recent-activity (D8) with `--days N' in
tincan.py; an undatable session is kept rather than hidden.
List format (one shared, scope-driven, title-first): `TITLE  DATE' for this
project, `TITLE  DATE  DIR' when broadened to all projects.  Title leads because it is the
identifier you scan for and front-anchors type-to-narrow; dir trails and only
when broadened.  One function builds the list for `tincan-resume' and
`tincan-view', so at a given scope they are identical (this was the original
complaint).  Earlier dir-first ordering was rejected: dir is redundant on the
left in the common single-project case and misaligns the rest.
DWIM "live group" detection matches a live terminal whose launch `cwd'
(stored buffer-locally in `tincan--cwd') is an ancestor-or-equal of
`default-directory'.  This catches a just-started session whose transcript file
does not exist yet (so it would be invisible to the on-disk listing), preventing
a duplicate `--resume' of an already-running session.
Ordering: tincan.py already sorts most-recently-active first (D8), but completion
UIs re-sort by default (Vertico by history/length/alpha), which discarded that
order.  `tincan--read-session' therefore wraps the alist in a completion table
(`tincan--session-collection') whose `metadata' declares
`display-sort-function'/`cycle-sort-function' = `identity', pinning the shown
order to the list order.  This also keeps `tincan-dwim' step 2 ("resume the
latest") consistent with what the picker shows on top.

### D41 - Hide the compose buffer without losing the draft
`tincan-compose-hide' (\`C-c C-z' in the compose buffer) buries the compose
buffer - it does NOT kill it - and quits its window via `quit-window' (deleting a
popped-up compose window, or restoring the previous buffer when it cannot be
deleted), so you can get the draft out of the way and consult the transcript.
Restore is free: `tincan-reply'
(\`r'/\`C-c SPC' in the view) already reuses an existing compose buffer
(`tincan--compose-buffer-for', keyed by terminal), so it pops the same draft
back.  `C-c C-z' was chosen over the message-mode idiom `C-c C-d' because the
latter shadows markdown-mode's `markdown-do'; a `C-c'-prefixed key is required
since the compose buffer is editable.
Known limitation: restore via `tincan-reply' runs the reply gate first, so if
Claude is now at a needs-input prompt it steers to the terminal instead of
reopening compose; the buried draft persists and is reachable via normal buffer
switching.

### D42 - Keep terminal prompts on-screen with `scroll-margin`
A tincan terminal sets a buffer-local `scroll-margin'
(`tincan-terminal-scroll-margin', default 8) so Claude's permission prompts and
menus stay fully visible.  Such a prompt parks the cursor on the first option
with the remaining options printed below it; with the cursor pinned to the window
bottom (a terminal's usual behavior) those lower options sit off-screen until you
navigate down.  A bottom margin makes redisplay scroll so the lines below the
cursor show.
It does not disturb normal typing: at end of buffer there is nothing below the
cursor, so the margin cannot scroll - it only acts when content exists below
point (the menu case).  Emacs caps it at `maximum-scroll-margin' (25% of the
window), so short windows degrade gracefully; 0 disables it.
Chosen over a custom `window-scroll-functions'/recenter hook: `scroll-margin' is
native and does not fight vterm's redraw.  The hook remains a fallback if the
margin proves insufficient.

### D43 - Timestamp on every `@@@` marker, dimmed in the view
Each `@@@ ROLE' marker line ends with the record's time as `YYYY-MM-DD HH:MM:SS'
(a space, not `T', for readability), in local time via
`format_marker_time'/`format_block'.  It is when that block was recorded - a
USER prompt was sent, a TOOL_RESULT returned, a turn finished (DONE, after the
`(Ns)' parens) - so a resumed session's history shows when things happened.  The
blocks of one record share that record's timestamp (e.g. an assistant text plus
its tool_use), which is truthful: that is when the record was written.
tincan.py emits it (so `tail -f' users get it too, and only the script has each
record's timestamp; the Emacs view renders from that text).  The view dims it
with a `tincan-timestamp' face (inherits `shadow') via a font-lock keyword
placed last so it overrides the role face on the trailing span; the keyword
matches only a real `YYYY-MM-DD HH:MM:SS' at end of an `@@@' line, so markers
without a timestamp are untouched.  State detection is unaffected: it keys on the
`@@@ DONE' prefix, which still leads the line.

### D44 - Shift-RET inserts a newline in Claude's prompt (no submit)
`S-<return>' in the terminal runs `tincan-terminal-send-newline', which sends a
lone newline as a *bracketed paste* (`vterm-send-string "\n" t').  libvterm
drops the Shift modifier on Return, so a plain Shift-RET reaches Claude as a bare
CR and its TUI submits; a bracketed paste is inserted literally, so the newline
lands in the input instead - the same trick tincan uses for multi-line replies.
The binding lives in `tincan-terminal-mode-map' (a minor-mode map, so it outranks
vterm's own Return handling) rather than in `vterm-mode-map', so it applies to
tincan terminals only.  On a tty frame it needs a keyboard protocol such as kkp
so `S-<return>' arrives as a distinct key; otherwise Emacs shift-translates it to
plain RET and the binding never fires.  (Previously lived in the user's personal
`wrap-vterm.el' on `vterm-mode-map'; moved here as the owning concern.)

### D45 - `tincan-conversation-only': hide whole noise sections (not fold)
`c' toggles `tincan-conversation-only', which hides every section whose role is
not in `tincan-unfolded-sections' (default USER/ASSISTANT) - the *whole* section,
heading line included, not just its body as folding (D22) does.  This is a filter
(invisibility), a different mechanism from folding.
It hides with an invisible *overlay* (value `tincan-conversation', added to
`buffer-invisibility-spec' as a bare symbol so there is no ellipsis) over each
section's span, from its @@@ heading to the next @@@ marker; the overlays are
tracked buffer-locally and deleted to reveal.  Overlays, not a text property,
because Markdown mode lists `invisible' in `font-lock-extra-managed-props', so a
text property is stripped on the next refontification - leaving only the
between-block newlines hidden (the symptom that forced this).  The dedicated
value also keeps it decoupled from outline folding: `outline-show-all'/S-TAB
remove only `invisible'=`outline' overlays, so these survive.
The stray-ellipsis fix is the subtle part.  The hiding overlay's own value never
draws an ellipsis (bare spec), but a *folded conversation* section sitting right
before a hidden noise section does: outline's `(outline . t)' spec draws its
`...', and because the collapsed noise leaves no visible newline after it, that
ellipsis renders against the *next* visible heading - a leading `...'.  It is the
outline invisibility, not ours, so a `display' property on our overlay cannot
suppress it.  So while hiding, `tincan--outline-ellipsis' swaps the `outline'
spec from `(outline . t)' to the bare symbol, silencing every fold ellipsis for
the duration (restored on reveal); folded conversation sections then show as bare
headings, which reads cleaner for this mode anyway.  A high `priority' on the
hiding overlay outranks any fold overlay underneath for good measure.
Navigation skips the hidden sections.  `tincan--move-marker' (M-n/M-p sections,
[/] turns) now skips matches whose start is `invisible-p'.  n/p were repointed
from `outline-next-visible-heading' to `tincan-next-heading', which drives the
same helper with an all-headings regexp - equivalent to the outline command for
folds (a folded heading stays visible; a heading hidden inside a folded ancestor
is `invisible-p' and skipped either way) but also skipping conversation-hidden
sections, which the outline command would not (`outline-invisible-p' only tests
for the `outline' value).  `u' stays on `outline-up-heading' (it only climbs
within a visible section).
It was originally a snapshot - sections streaming in while it was on stayed
visible until the next toggle - which D52 replaced with an incremental pass, so
it now keeps up with the stream.  Reusing `tincan-unfolded-sections' keeps this
"conversation" notion aligned with the default fold set rather than hardcoding
the two roles.

### D46 - Auto-align Markdown tables via `markdown-table-align'
The view aligns Markdown tables automatically as sections stream in
(`tincan-format-tables', default t).  The alignment itself is `markdown-mode''s
own `markdown-table-align', not a hand-rolled aligner: it already respects the
delimiter row's alignment colons (`:---'/`---:'/`:--:') and uses
`markdown--string-width' for correct Unicode/CJK widths - both of which a custom
aligner would have to re-implement and likely get subtly wrong.  The cost is that
it needs a Markdown-table mode active (`markdown-mode'/`gfm-mode'), so it is a
no-op in the plain `tincan-view-mode' fallback and in bare `markdown-ts-mode';
`tincan--tables-available-p' gates on `derived-mode-p 'markdown-mode'.
Application mirrors `tincan--autofold' (D22): a buffer-local `tincan--table-marker'
tracks progress; each complete @@@ section (one that already has a successor) has
its tables aligned once and the marker advanced past it, and the last section is
aligned too but the marker is left before it so it is re-aligned as more streams
in.  Tables never arrive *partial* at the record level (tincan.py renders one
whole JSONL record at a time), but chunked pipe I/O can split a section across
filter chunks, hence the complete-section guard; `markdown-table-at-point-p' also
needs a delimiter row, so a half-arrived table is skipped until it is real.
`markdown-table-at-point-p' excludes fenced code, so tables inside tool output are
left alone; `tincan--align-tables-in' `syntax-propertize's the region first so
that exclusion is accurate on freshly streamed, not-yet-fontified text.  Runs from
the filter after `tincan--autofold'; `tincan-align-tables' is a manual whole-buffer
re-run (which works even when `tincan-format-tables' is nil, since it is an
explicit request).

### D47 - Record framing plus a long-line emphasis guard
A 37k-character line in a tool result (JSON nested inside a JSON string) wedged
Emacs at 100% CPU inside `markdown-match-italic', under `redisplay_internal'
where quitting is inhibited.  The complete line is harmless - it sits in a
closed code fence, which the emphasis matchers skip - but pipe chunking used to
let `tincan--filter' insert a fence's contents before its closing fence
arrived, exposing the raw text to the emphasis regexps, whose backtracking is
superlinear in line length.  Two layers fix this without modifying content
(wrapping/truncating long lines was rejected: it breaks copy fidelity, can
fabricate line-start syntax - including phantom `@@@' markers - and corrupts
tables).
Layer one: framing.  tincan.py terminates each rendered record with an ASCII
record separator (0x1E) in --follow mode only (plain output stays clean for
other consumers), stripping stray 0x1E from bodies so framing stays sound.  The
filter buffers chunks in `tincan--pending-output' and inserts only up to the
last separator, so fences always arrive closed; a pipe is a boundary-less byte
stream, hence an explicit separator rather than parsing fence balance in elisp
(which would duplicate markdown's fence grammar) or timing heuristics.  The
sentinel flushes an unterminated tail (e.g. a follower error) that framing
would otherwise withhold forever.  Records are whole JSONL lines, so framing
adds no perceptible latency.
Layer two: the guard, for long lines that are legitimately unfenced (prose, or
a transcript whose own text carries unbalanced backticks).  Before insertion
the filter checks the record for a line over `tincan-long-line-threshold'
(default 2000; nil disables) and sets buffer-local
`tincan--emphasis-suppressed', consulted by :around advice on
`markdown-match-italic' / `markdown-match-bold' (advice rather than
`font-lock-keywords' surgery: it survives keyword compilation, and restoring is
just clearing the flag).  The check runs before insertion so fontification
never sees the line unguarded.  The header line shows `[no emphasis]';
`tincan-refontify' (`e') clears the flag and `font-lock-flush'es - gated on the
agent not being mid-turn since a complete transcript's long lines are all
fenced, `C-u' forces - and the guard simply re-arms if a later record brings
another long line.  Lowering `long-line-threshold' instead was tested and does
not help: the blowup starts below any reasonable threshold, while the wedge is
a single uninterruptible fontification call.

### D48 - Confirm a new session started outside a project root
`tincan--start-new' now asks `%s is not a project root; start Claude here
anyway?' unless `default-directory' is a project root, and aborts with a
`user-error' on a "no".  This reaches both entry points that create a session:
`tincan-start' and `tincan-dwim''s third branch (resume paths are unaffected -
they relaunch in the session's own recorded `cwd' per D40, which was vetted when
that session was created).
The launch directory is load-bearing, which is why the mistake is worth a
keystroke: Claude indexes and searches from its cwd, and tincan derives session
identity from it - tincan.py lists sessions by the closest launch directory at or
above the working directory (D11), and DWIM's live-group match is
ancestor-or-equal on `tincan--cwd' (D40).  Starting one directory too deep gives
Claude a partial view of the tree and hides that session from the picker you use
at the root, and neither symptom points back at the cause.
Rootness is `project-current' / `project-root', not a hand-rolled `.git' probe:
the VC backend already covers plain checkouts with no configuration, and
deferring to project.el means `project-vc-extra-root-markers' (monorepo
packages, `.project' files) and `project-vc-merge-submodules' keep working as
the user configured them.  Comparison is `file-equal-p', so symlinks and
unnormalized paths do not produce a spurious prompt.
A directory in no project at all prompts too, rather than passing silently.  The
rule is then one sentence with no exception to remember, and the ad-hoc case
(`~', a scratch dir) is exactly where a mistyped or forgotten `cd' lands - the
reading where "not a root" excuses itself is the one where the check would have
helped most.  No defcustom to disable it: `y-or-n-p' is one keystroke, and a knob
would need its own documentation and a decision here for no real gain.

### D49 - Render an `Edit` tool use as a unified diff (extends D39)
An `Edit' tool_use is rendered as a unified diff of its `old_string' against its
`new_string', fenced as ```diff, with the file path on the `@@@ TOOL_USE' marker
line exactly as D39 does for `Write'.  This lifts D39's "not handled" note: the
two payloads do fit a single block once they are diffed.
Rationale: the JSON rendering printed the same snippet twice, escaped, as one
`\n'-laden line per field, so the reader had to find the difference by eye across
two walls of text - the change itself, the only thing the block is about, was
never actually shown.  A diff marks it directly, which matters because Claude's
`old_string' routinely carries a long unchanged prefix or suffix just to anchor
the match.  The ```diff fence then buys
`diff-mode' fontification of the body for free through native code-block
fontification (D17), so additions, removals and hunk headers are colored with no
new faces and no new keywords on the Emacs side.
No `---'/`+++' file header is emitted.  The path is already on the marker line
(D39), and without a header `diff-mode' will not try to refine the hunks against
the file's *current* contents, which need not resemble what the transcript
recorded.  The hunk headers' line numbers are relative to the snippet, because a
tool_use records the old and new strings but not their offset in the file; the
diff therefore reads but does not apply, and `w' on the block copies a diff, not
a patch.
Lines are split on `\n' rather than with `str.splitlines()'.  This is a fidelity
requirement, not a stylistic preference: `splitlines()' also breaks on `\v',
`\f', `\x1c'-`\x1e', `\x85', U+2028 and U+2029, and because the body is rejoined
with `\n', every one of those characters would be silently rewritten into a real
newline in the rendered block - content corruption, in a viewer whose whole pitch
is a faithful transcript.  It is not hypothetical here: a form feed is the
idiomatic page separator in Emacs Lisp, and `\x1e' is tincan's own record
separator (D47), so both are characters this project edits in its own sources.
`split("\n")' is lossless (a bijection with the string), and its trailing empty
field additionally keeps a final newline visible, so an edit that only adds or
removes one still shows a difference instead of rendering as two identical texts.
The cost of that last property: when exactly one side ends in a newline the diff
shows a blank line being added or removed that is not really there.  Measured at
3 of 1141 real Edit blocks (0.3%), so it is not worth the `\ No newline at end of
file' machinery that would suppress it.
Malformed input (a missing `old_string'/`new_string') and the degenerate no-op
edit, whose diff is empty, fall back to the D7/D18 JSON rendering, so a block is
never silently swallowed by `format_block''s empty-body rule.  A `Write' whose
`content' is not a string falls back the same way, for the same reason.
That fallback discipline is backed by `marker_text', which every value destined
for a marker line now passes through - the tool name and, in both renderers, the
file path.  A tool_use's fields are model-written JSON, so nothing guarantees
their type or content, and three distinct shapes were reachable: a number raises
on concatenation, a list is not hashable and breaks the `CONTENT_TOOLS' lookup,
and an embedded newline forges a second line - one starting with `@@@' would fake
a section marker and split the block in the view.  The stakes are set by D10:
`handle_line' guards only against JSON errors, so anything raised while rendering
escapes it and takes down the follower mid-session, turning a malformed record
into a dead live view.  `marker_text' returns a substitute (`""' for a path, `?'
for a name) instead, so a bad record degrades to a slightly bare marker line.
Verified by exhaustively rendering every JSON-representable shape in each slot -
51840 inputs, no exceptions raised.
Note what this does *not* cover: a body rendered verbatim (a `Write''s content, a
tool result, message prose) can still contain a line beginning with `@@@' and
forge a marker, which the same sweep confirms.  That is inherent to D6's marker
choice - it buys reliable font-locking on the premise that `@@@' is rare at line
start - and escaping bodies to close it was already rejected under D47 as a
copy-fidelity loss.  The guard covers the marker line, which tincan composes and
therefore controls, not the body, which it must reproduce faithfully.
The marker, outline and state regexes are unaffected (D14, D22): no diff line can
begin with `@@@' - context, added and removed lines all carry a one-character
prefix, and a hunk header has exactly two `@' before its space.

Context is `max(len(old_lines), len(new_lines))', not difflib's default 3, so the
diff is a pure presentation layer over the excerpt rather than a lossy summary of
it - nothing is ever collapsed, and there is always exactly one hunk.  The
distinction matters because `n' means something different here than in an
ordinary diff.  Normally the two sides are whole files and dropped context costs
nothing, because the reader can open the file; here the two sides are the excerpt
Claude chose to send, which exists nowhere in the transcript but this record, so
collapsing a run of unchanged lines does not elide it, it deletes it - directly
against the "faithful history" claim the viewer is built on.
Measured over 1141 real Edit blocks: at `n=3', 72 blocks (6.3%) lost at least one
excerpt line, 301 lines in total, the worst hiding 22 lines of a 39-line excerpt
whose changes sat at both ends.  Full context costs 528 extra rendered lines
across those 1141 blocks - 0.46 lines per block - which is nothing next to a
6.3% hole in the record, especially since the sections start folded (D22) so
block length is barely felt.  `n=20' would also have reached zero on this corpus,
but only by accident of the largest excerpt seen so far; deriving `n' from the
input needs no such luck.
The residual cost is the reverse case: a very large Edit renders in full instead
of as a tight summary.  Only one Edit in the corpus has a 200+ line side, and
`diff-mode' colors the changed lines anyway, so the change stays findable.  That
one block is also the only one anywhere near difflib's `autojunk' heuristic,
which (for `len(new_lines) >= 200') drops lines occurring more than
`len(new_lines) // 100 + 1' times from the match index and would fragment the
hunk; `unified_diff' exposes no way to disable it, so if large edits ever become
common the fix is to build hunks from `SequenceMatcher(..., autojunk=False)'
directly.  Not worth doing for one block.

### D50 - Word-level refinement of rendered Edit diffs (extends D49)
The ```diff blocks D49 renders now also mark the *changed words* within a hunk,
using `diff-mode''s own refinement and its `diff-refine-added' /
`diff-refine-removed' faces, so a theme that already styles a refined diff needs
no further setup and tincan adds no faces of its own.  `tincan-refine-diffs'
(default t) turns it off.
It needs a bridge, which is the whole reason this is a decision rather than a
one-liner.  `diff-mode' records refinement as *overlays* (`smerge-refine-regions'
via `smerge--refine-highlight-change', which calls `make-overlay' unconditionally
- there is no text-property mode), while `markdown-fontify-code-block-natively'
fontifies a code block by copying text *properties* back from a throwaway temp
buffer.  Overlays are simply dropped, so nothing survived: measured, a plain
`diff-mode' buffer carries 6 overlays including `diff-refine-removed', and the
same text through the markdown path carries 0, leaving only `(diff-removed
markdown-code-face)'.
So tincan does the copying itself.  `tincan--refine-spans' runs `diff-mode' over
a copy of the block in a temp buffer (mode hooks suppressed with
`delay-mode-hooks' - the buffer is discarded, and a user's `diff-mode-hook' has
no business running once per rendered block), reads the offsets of the spans it
marked, and `tincan--refine-block' recreates them as overlays in the view.
Offsets map one-to-one because the temp buffer holds exactly the block text.
Overlays rather than text properties in the view as well, for the D45 reason:
font-lock manages `face', so a property would be stripped on the next
refontification, whereas an overlay survives and works in a read-only buffer,
which D22's folding already depends on.
Application mirrors `tincan--align-new-tables' (D46) and `tincan--autofold'
(D22): a buffer-local `tincan--refine-marker' advances over @@@ sections that
already have a successor, so a half-arrived block is never refined against a
partial hunk.  Re-running over a section is idempotent because
`tincan--refine-diffs-in' clears that block's overlays before re-adding them,
which is what makes the still-arriving last section safe to redo on every chunk.
`tincan-refine-diff-blocks' is the manual whole-buffer re-run, mirroring
`tincan-align-tables'.
Refinement shells out to the external `diff-command' once per hunk, tincan's
first hard runtime dependency on a program rather than a library, so it is
written to degrade rather than fail.  `tincan--diff-program-available-p' caches a
single `executable-find' per session (the lookup would otherwise repeat per
block); without the program the streaming path is a silent no-op and only the
explicit command reports why, since a message per rendered block would be worse
than no refinement.  `tincan--refine-block' additionally wraps the work in
`condition-case': a block that cannot be refined is left plain rather than
allowed to break the insertion streaming it in.  Hunks over
`diff-refine-threshold' (30000 chars) are skipped by `diff-mode' itself.
Gated on `derived-mode-p 'markdown-mode' plus
`markdown-fontify-code-blocks-natively', i.e. on the native fontification that
colors the diff body in the first place (D17).  Alone - in the
`tincan-view-mode' fallback, or with code blocks left unfontified - refinement
would mark words inside otherwise uncolored text, which reads worse than no
refinement at all.
Overlay count is not a performance concern on the supported Emacs (D23 floor is
30.1, and Emacs 29 replaced the overlay list with an interval tree).  Measured on
a 2 MB, 39293-line transcript: appending 2 KB at end of buffer 200 times - the
D21 filter's hot path - takes 0.0010 s with no overlays and 0.0009 s with 20000,
i.e. flat, where the pre-29 implementation would have been linear in overlay
count; a `vertical-motion' sweep of the whole buffer goes 0.028 s -> 0.047 s
between the same extremes, and real redisplay only lays out a window's worth.
Fontifying that buffer costs ~9 s regardless of overlays, so font-lock dominates
by three orders of magnitude.  The realistic load is 3760 spans over 310 diff
blocks, applied in 0.71 s for the whole buffer and one block at a time while
streaming.
This closes D49's open question about the `@@' hunk header: it must stay.
Refinement needs a hunk header with *correct* line counts - with the header
removed, or with counts that disagree with the body, `diff-mode' finds no hunk
and marks nothing.  difflib always emits correct counts, so the requirement is
met, but dropping the header to hide its snippet-relative line numbers would
now silently cost word-level highlighting too.

### D51 - An unsent compose draft survives killing Emacs
Compose (D34) is a plain buffer visiting no file, which made it the one place in
tincan where work could vanish without a word: `save-buffers-kill-emacs' asks
about modified *file* buffers, so exiting with a half-written reply in compose -
especially one hidden with `C-c C-z' (D41) - took it along silently.  The kill
guard added in D34 does not fire either; `kill-buffer-query-functions' is not
consulted when Emacs exits.
So the draft is persisted per session, as `<config-dir>/tincan/<session-id>.draft'
- the directory the notify files already live in (D20), keyed the same way, so
one session's drafts never reach another's.  A session id is required: a compose
buffer whose terminal has died has nothing to key on and is simply not
persisted, which is also why `tincan--draft-file' returns nil rather than
inventing a name.  The extra writes are invisible to the rest of the system:
tincan.py only ever names `<id>.notify' directly, and the D20 watcher filters
events by exact basename, so `.draft' traffic in that directory cannot be
mistaken for a `needs-input' signal.
Writing it is Emacs' own auto-save rather than a timer of tincan's.  Setting
`buffer-auto-save-file-name' in a non-file buffer *is* what enabling auto-save
means (the minor mode does nothing else, and would insist on a `#name#' of its
own), so the draft gets written on whatever cadence the user has configured, and
`do-auto-save' is code that has been debugged since the 1980s.  Two explicit
flushes cover what auto-save's cadence can miss: `kill-emacs-hook' (a normal
exit does not auto-save - only the crash path in `shut_down_emacs' does), and
`tincan-compose-hide', because a hidden draft is precisely the one that gets
forgotten.  Both go through `tincan--compose-save-draft', which is wrapped in
`condition-case': a failed draft write must never break composing, and on
`kill-emacs-hook' an error would block the exit itself.
Restoring is deliberately not `recover-file'-style archaeology.  A fresh compose
buffer for a session with a draft on disk reads it back, leaves point after it,
and says "draft restored"; the buffer is marked unmodified so auto-save does not
immediately rewrite an identical file.  Nothing changes for a live session: the
D41 reuse path (`tincan--compose-buffer-for') finds the existing buffer first,
so the file is only ever read when the buffer is gone - i.e. after an Emacs
restart.
Deleting it is `kill-buffer-hook', which covers both endings at once: a send
force-kills compose (D34), and a discard has already been confirmed by the D34
query.  Emacs would delete an auto-save file on kill anyway, but relying on that
would tie a user-visible guarantee to internal `kill-buffer' conditions.  An
empty or whitespace-only draft deletes the file instead of writing one, so
clearing compose and exiting leaves nothing to restore.
`tincan-persist-drafts' (default t) turns the whole thing off, in which case no
draft file is ever created.  Known and accepted: a draft for a session that is
never resumed keeps its file until removed by hand.  Pruning would need a policy
(age?  dead session?) and the files are tiny; a stale one costs nothing until the
day that session is resumed, when it is arguably what you wanted.

### D52 - `tincan-conversation-only' keeps up with the stream (extends D45)
Hiding used to be a snapshot of the moment `c' was pressed: every section that
streamed in afterwards arrived visible, so watching a live session with the
noise hidden meant pressing `c' twice again after each tool call.  Hiding is now
incremental, `tincan--hide-new-sections' running from the filter after the D22
autofold, the D46 table alignment and the D50 diff refinement - the same
marker-driven shape as those three: `tincan--hide-marker' records how far the
transcript has been hidden, each pass resumes there, and sections already passed
are never revisited (a section revealed by hand stays revealed, as with folds).
The whole-buffer pass is the same code: `tincan--hide-other-sections' now only
arms the invisibility spec and resets the marker to `point-min' before calling
the incremental one.  So there is exactly one place that decides what gets
hidden, and the toggle-on view and the streaming view cannot drift apart.
The subtlety is where the *last* section ends.  A hiding overlay runs from a
section's @@@ heading to the next one, and for the trailing section that heading
has not arrived yet, so its overlay runs to `point-max' and is remembered in
`tincan--hide-tail-overlay': the next heading found closes it at its own start,
and until then each pass stretches it to `point-max' again (an overlay does not
grow by itself - text inserted at its end lands outside it).  That stretch only
matters for a record that carries no @@@ heading of its own; under D47 records
are whole rendered sections, so in practice each pass closes one overlay and
opens the next.
The trailing section is hidden as soon as its heading lands, rather than waiting
for the next heading the way `tincan--autofold' waits before folding.  The two
want opposite things: a fold on a still-arriving section would hide text you are
watching arrive, whereas the point of this mode is that the noise never appears
at all - and because records are complete sections, waiting would leave a
TOOL_USE on screen for the whole of the tool call and a TOOL_RESULT until the
next turn began, which is most of what there is to hide.
Consequence, accepted: the follower keeps setting `window-point' to `point-max'
(D30's tail following), which is now inside an invisible run whenever the last
section is noise.  In a window that is not selected nothing disturbs it, so
following keeps working and the next conversation section scrolls into view; in
the selected window Emacs' own point adjustment pulls point out of the invisible
text at the next command, landing at the end of the visible transcript - which
is where toggling `c' on puts it anyway.
`tincan-conversation-only' now sets `tincan--conversation-only' before hiding or
revealing rather than after, since the shared pass tests that flag to decide
whether it should do anything.
