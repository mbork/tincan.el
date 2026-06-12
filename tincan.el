;;; tincan.el --- Drive Claude Code from Emacs via tmux -*- lexical-binding: t; -*-

;; Author: Marcin 'mbork' Borkowski <mbork@mbork.pl>
;; Maintainer: Marcin 'mbork' Borkowski <mbork@mbork.pl>
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, processes
;; URL: https://github.com/mbork/tincan.el

;;; Commentary:

;; tincan is a hackish take on agentic coding in Emacs: it drives Claude Code
;; via tmux.  This file handles the display side of a Claude Code transcript
;; produced by tincan.py.
;;
;; Call `tincan-render-buffer' to set up the current buffer for viewing: it
;; renders the conversation with a Markdown mode when one is available (see
;; `tincan-markdown-mode'), otherwise it falls back to `tincan-view-mode'.
;; Either way the "@@@ ROLE" section markers are font-locked and the buffer is
;; made read-only.
;;
;; The transcript is plain text meant to be followed with
;; `auto-revert-tail-mode', so this file only handles display.

;;; Code:

;; * Customization group
(defgroup tincan nil
  "Drive Claude Code from Emacs via tmux."
  :group 'tools
  :prefix "tincan-")

;; * The tincan.py script
(defconst tincan--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing tincan.el, used to locate tincan.py.")

(defcustom tincan-script
  (expand-file-name "tincan.py" tincan--directory)
  "Path to tincan.py, the helper that prints, follows and manages sessions."
  :type 'file
  :group 'tincan)

;; * Faces
(defface tincan-user
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the \"@@@ USER\" marker line."
  :group 'tincan)

(defface tincan-assistant
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the \"@@@ ASSISTANT\" marker line."
  :group 'tincan)

(defface tincan-thinking
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for the \"@@@ THINKING\" marker line."
  :group 'tincan)

(defface tincan-tool-use
  '((t :inherit font-lock-builtin-face))
  "Face for the \"@@@ TOOL_USE\" marker line."
  :group 'tincan)

(defface tincan-tool-result
  '((t :inherit font-lock-string-face))
  "Face for the \"@@@ TOOL_RESULT\" marker line."
  :group 'tincan)

(defface tincan-done
  '((t :inherit success :weight bold))
  "Face for the \"@@@ DONE\" marker line that ends a turn."
  :group 'tincan)

;; * Font lock
;; The markers below must stay in sync with tincan.py's ROLE_* constants.
(defvar tincan-font-lock-keywords
  '(("^@@@ USER.*$" 0 'tincan-user t)
    ("^@@@ ASSISTANT.*$" 0 'tincan-assistant t)
    ("^@@@ THINKING.*$" 0 'tincan-thinking t)
    ("^@@@ TOOL_USE.*$" 0 'tincan-tool-use t)
    ("^@@@ TOOL_RESULT.*$" 0 'tincan-tool-result t)
    ("^@@@ DONE.*$" 0 'tincan-done t))
  "Font-lock keywords highlighting the \"@@@ ROLE\" section markers.
Used directly by `tincan-view-mode' and added on top of Markdown
fontification by `tincan-render-buffer'.  The trailing OVERRIDE flag makes the
marker faces win even when a Markdown mode has already fontified the line.")

;; * View mode
;;;###autoload
(define-derived-mode tincan-view-mode special-mode "Tincan"
  "Plain-text fallback mode for viewing a tincan transcript.

Used by `tincan-render-buffer' when no Markdown mode is available.  The buffer
is read-only; new content is expected to arrive via `auto-revert-tail-mode'.
Section markers of the form \"@@@ ROLE\" are font-locked according to the
`tincan-user', `tincan-assistant', `tincan-thinking', `tincan-tool-use',
`tincan-tool-result' and `tincan-done' faces."
  (setq-local font-lock-defaults '(tincan-font-lock-keywords t)))

;; * Folding
;; The @@@ sections are foldable with `outline-minor-mode'.  With
;; `outline-minor-mode-cycle', TAB on a section's @@@ heading cycles its
;; visibility and S-TAB cycles the whole buffer.  Every section except those in
;; `tincan-unfolded-sections' starts folded, so thinking, tool calls/results and
;; DONE markers stay out of the way until opened.  Folding uses overlays, so it
;; works in the read-only buffer; auto-folding is marker-driven so manual
;; unfolds are preserved.
(require 'outline)

(defcustom tincan-unfolded-sections '("USER" "ASSISTANT")
  "Roles of \"@@@ ROLE\" sections shown expanded by default.
Every other section (THINKING, TOOL_USE, TOOL_RESULT, DONE, ...) starts folded."
  :type '(repeat string)
  :group 'tincan)

(defvar-local tincan--fold-marker nil
  "Marker up to which streamed @@@ sections have been auto-folded.")

(defun tincan--default-folded-p (role)
  "Non-nil if a section with ROLE should start folded."
  (not (member role tincan-unfolded-sections)))

(defun tincan--autofold ()
  "Fold complete, default-folded @@@ sections from `tincan--fold-marker'.
A section is complete once another @@@ heading follows it; the last (still
arriving) section is left open until its successor shows up.  Sections already
passed are not revisited, so manual unfolding is preserved."
  (when tincan--fold-marker
    (save-excursion
      (goto-char tincan--fold-marker)
      (catch 'incomplete
        (while (re-search-forward "^@@@ \\([A-Z_]+\\)" nil t)
          (let ((role (match-string 1))
                (heading (match-beginning 0)))
            (unless (save-excursion (re-search-forward "^@@@ " nil t))
              (set-marker tincan--fold-marker heading)
              (throw 'incomplete nil))
            (when (tincan--default-folded-p role)
              (save-excursion (goto-char heading) (outline-hide-subtree)))
            (set-marker tincan--fold-marker (line-end-position))))))))

(defun tincan--outline-level ()
  "Outline level: @@@ sections are level 1; Markdown headings nest below them."
  (if (looking-at-p "@@@ ")
      1
    (1+ (save-excursion
          (beginning-of-line)
          (skip-chars-forward "#")))))

(defun tincan--setup-folding ()
  "Enable folding in the current buffer and apply the default fold.
Both @@@ section markers and Markdown headings are outline headings, so TAB
cycles either; @@@ sections are top level and Markdown headings nest within.
Markdown headings go through `outline-cycle' here rather than `markdown-cycle',
which would misnavigate because `outline-regexp' is not Markdown's."
  (setq-local outline-regexp "\\(?:@@@\\|#+\\) ")
  (setq-local outline-level #'tincan--outline-level)
  (setq-local outline-minor-mode-highlight nil)
  (setq-local outline-minor-mode-cycle t)
  (outline-minor-mode 1)
  (setq-local tincan--fold-marker (copy-marker (point-min)))
  (tincan--autofold))

;; * Rendering
(defcustom tincan-markdown-mode t
  "How to render a tincan transcript with Markdown.
If t, auto-detect and use `gfm-mode' or `markdown-mode' when available.
If nil, never use Markdown (always fall back to `tincan-view-mode').
If a function symbol, call it as the major mode when it is `fboundp'
\(for example `markdown-view-mode' or `gfm-view-mode')."
  :type '(choice (const :tag "Auto-detect gfm-mode/markdown-mode" t)
                 (const :tag "Disabled (plain fallback)" nil)
                 (function :tag "Specific Markdown mode"))
  :group 'tincan)

(defcustom tincan-fontify-code-blocks-natively t
  "If non-nil, fontify fenced code blocks with each language's major mode.
Only has an effect when a Markdown mode is used (see `tincan-markdown-mode'):
it sets `markdown-fontify-code-blocks-natively' buffer-locally.  Turning this
off avoids loading language major modes, which can matter for a large,
continuously tailed transcript."
  :type 'boolean
  :group 'tincan)

;; Declared by markdown-mode; forward declaration keeps the byte-compiler quiet.
(defvar markdown-fontify-code-blocks-natively)

(defun tincan--markdown-mode-symbol ()
  "Return the Markdown major-mode symbol to use, or nil.
Honors `tincan-markdown-mode' and only returns a mode that is `fboundp'."
  (cond ((null tincan-markdown-mode)
         nil)
        ((eq tincan-markdown-mode t)
         (cond ((fboundp 'gfm-mode) 'gfm-mode)
               ((fboundp 'markdown-mode) 'markdown-mode)
               (t nil)))
        ((and (symbolp tincan-markdown-mode) (fboundp tincan-markdown-mode))
         tincan-markdown-mode)
        (t nil)))

;;;###autoload
(defun tincan-render-buffer ()
  "Set up the current buffer to display a tincan transcript.
Render the conversation with a Markdown mode when one is available (see
`tincan-markdown-mode'), otherwise fall back to `tincan-view-mode'.  In both
cases the \"@@@ ROLE\" markers are font-locked and the buffer is read-only."
  (interactive)
  (let ((markdown-mode-symbol (tincan--markdown-mode-symbol)))
    (if markdown-mode-symbol
        (progn
          (funcall markdown-mode-symbol)
          (setq-local markdown-fontify-code-blocks-natively
                      tincan-fontify-code-blocks-natively)
          (font-lock-add-keywords nil tincan-font-lock-keywords 'append)
          (setq buffer-read-only t)
          (font-lock-flush))
      (tincan-view-mode)))
  ;; Soft-wrap long prose and tool output at word boundaries.
  (visual-line-mode 1)
  (tincan--setup-folding))

;; * Notification hook
;; Optional integration: a Claude Code "Notification" hook runs tincan.py,
;; which writes a small per-session file when Claude is waiting for input (e.g.
;; a tool-permission prompt).  All settings.json editing is done by the Python
;; script, so the installed command and its paths have a single source of truth;
;; the commands below are thin wrappers around it.  Installing is opt-in and only
;; signals "Claude wants you" - it does not handle tool selection.

(defcustom tincan-hook-settings-file nil
  "Settings file the Notification hook is installed into.
When nil, tincan.py uses its own default,
\".claude/settings.local.json\" relative to the working directory."
  :type '(choice (const :tag "Script default" nil) file)
  :group 'tincan)

(defun tincan--run-hook-script (subcommand)
  "Run tincan.py with SUBCOMMAND, echo its output, return its exit code."
  (let ((args (if tincan-hook-settings-file
                  (list subcommand "--settings-file" tincan-hook-settings-file)
                (list subcommand))))
    (with-temp-buffer
      (let* ((code (apply #'call-process "python3" nil t nil
                          tincan-script args))
             (output (string-trim (buffer-string))))
        (unless (string-empty-p output)
          (message "%s" output))
        code))))

;;;###autoload
(defun tincan-install-hook ()
  "Install tincan's Notification hook (via tincan.py).
Installing is optional; tincan works without it.  The script backs up the
settings file first.  Afterwards, restart Claude Code or run /hooks so the
change is reviewed and loaded."
  (interactive)
  (tincan--run-hook-script "--install-hook"))

;;;###autoload
(defun tincan-uninstall-hook ()
  "Remove tincan's Notification hook (via tincan.py)."
  (interactive)
  (tincan--run-hook-script "--uninstall-hook"))

;;;###autoload
(defun tincan-hook-installed-p ()
  "Return non-nil if tincan's Notification hook is installed.
Interactively, report the result in the echo area."
  (interactive)
  (= 0 (tincan--run-hook-script "--check-hook")))

;; * Session orchestration
;; `tincan' picks one of this project's sessions and watches it live: it runs
;; tincan.py --follow as an async process and feeds the output into a
;; rendered, read-only buffer through a process filter.  Output may arrive in
;; arbitrary chunks (even mid-line), so the filter follows the marker idiom -
;; insert at the process mark, and process only newline-terminated lines.
(require 'filenotify)

(defvar-local tincan--process nil
  "The tincan.py --follow process feeding the current buffer.")

(defvar-local tincan--session-id nil
  "The Claude Code session id shown in the current buffer.")

(defun tincan--short-id (session-id)
  "Return a short, buffer-name-friendly form of SESSION-ID."
  (substring session-id 0 (min 8 (length session-id))))

(defcustom tincan-buffer-title-width 16
  "Columns the session title is abbreviated to in the viewer buffer name."
  :type 'integer
  :group 'tincan)

(defun tincan--buffer-name (session-id title)
  "Return the viewer buffer name for SESSION-ID, using TITLE when non-empty.
TITLE is abbreviated to `tincan-buffer-title-width' columns; with no usable
TITLE the short id is used."
  (let* ((trimmed (and (stringp title) (string-trim title)))
         (label (if (and trimmed (not (string-empty-p trimmed)))
                    (truncate-string-to-width trimmed tincan-buffer-title-width)
                  (tincan--short-id session-id))))
    (format "*tincan: %s*" label)))

;; ** Session selection
(defun tincan--list-sessions ()
  "Return an alist of (DISPLAY . (ID . TITLE)) for this project's sessions.
DISPLAY is \"TIMESTAMP  TITLE\".  Runs tincan.py in `default-directory',
whose sessions are the ones it lists."
  (with-temp-buffer
    (let ((code (call-process "python3" nil t nil tincan-script "--show-sessions")))
      (unless (= code 0)
        (error "tincan: --show-sessions failed: %s" (string-trim (buffer-string))))
      (let ((sessions '()))
        (goto-char (point-min))
        (while (not (eobp))
          (let* ((line (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position)))
                 (fields (split-string line "\t")))
            (when (>= (length fields) 3)
              (push (cons (format "%s  %s" (nth 1 fields) (nth 2 fields))
                          (cons (nth 0 fields) (nth 2 fields)))
                    sessions)))
          (forward-line 1))
        (nreverse sessions)))))

(defun tincan--read-session ()
  "Prompt for one of this project's sessions; return (ID . TITLE)."
  (let ((sessions (tincan--list-sessions)))
    (unless sessions
      (user-error "tincan: no sessions for %s" default-directory))
    (cdr (assoc (completing-read "tincan session: " sessions nil t) sessions))))

;; ** State and mode line
;; The agent's state is derived from the transcript stream: a `@@@ DONE' line
;; means the turn finished (idle); any other content means it is working.
;; `tincan--scan-marker' tracks how far we have scanned, so chunked/partial
;; lines are handled the same way the follower handles partial writes.
(defvar-local tincan--state nil
  "Current agent state for the buffer: nil, `working', `idle' or `needs-input'.")

(defvar-local tincan--scan-marker nil
  "Marker up to which output has been scanned for state markers.")

(defface tincan-state-working '((t :inherit warning))
  "Mode-line face shown while the agent is working."
  :group 'tincan)

(defface tincan-state-idle '((t :inherit success))
  "Mode-line face shown when the agent is idle (the turn finished)."
  :group 'tincan)

(defface tincan-state-needs-input '((t :inherit error :weight bold))
  "Mode-line face shown when Claude is waiting for your input."
  :group 'tincan)

(defun tincan--mode-line-string (state)
  "Return the mode-line indicator string for STATE."
  (pcase state
    ('working (propertize " [working]" 'face 'tincan-state-working))
    ('idle (propertize " [idle]" 'face 'tincan-state-idle))
    ('needs-input (propertize " [needs input]" 'face 'tincan-state-needs-input))
    (_ "")))

(defun tincan--set-state (state)
  "Set the buffer's tincan STATE and reflect it in the mode line."
  (unless (eq tincan--state state)
    (setq tincan--state state)
    (setq-local mode-line-process (tincan--mode-line-string state))
    (force-mode-line-update)))

(defun tincan--update-state-from-line (line)
  "Update the agent state from a completed transcript LINE."
  (cond ((string-prefix-p "@@@ DONE" line)
         (tincan--set-state 'idle))
        ((not (string-empty-p line))
         (tincan--set-state 'working))))

(defun tincan--scan-for-state (limit)
  "Scan complete lines from `tincan--scan-marker' up to LIMIT, updating state.
Only newline-terminated lines are scanned; the marker is left at the start of
any incomplete trailing line so a later chunk completes it."
  (save-excursion
    (goto-char tincan--scan-marker)
    (while (and (< (point) limit)
                (save-excursion (search-forward "\n" limit t)))
      (tincan--update-state-from-line
       (buffer-substring-no-properties (point) (line-end-position)))
      (forward-line 1))
    (set-marker tincan--scan-marker (point))))

;; ** Notification watch
;; The hook writes <config-dir>/tincan/<session-id>.notify when Claude wants
;; input (D20).  We watch the directory (the file may not exist yet) and flag
;; `needs-input' on a write; resumed transcript activity clears it back to
;; `working' or `idle'.
(defvar-local tincan--notify-watch nil
  "File-notify descriptor for this buffer's .notify status file, or nil.")

(defun tincan--config-dir ()
  "Return Claude Code's config directory (honoring CLAUDE_CONFIG_DIR)."
  (expand-file-name (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude")))

(defun tincan--notify-file (session-id)
  "Return the notify status file the hook writes for SESSION-ID.
Mirrors tincan.py's notify_status_path."
  (expand-file-name (concat session-id ".notify")
                    (expand-file-name "tincan" (tincan--config-dir))))

(defun tincan--setup-notify-watch (session-id)
  "Watch SESSION-ID's notify file and flag `needs-input' on change.
Return the watch descriptor, or nil.  Failures are non-fatal: the indicator
just will not appear if the optional hook is absent or watching is unsupported."
  (let* ((file (tincan--notify-file session-id))
         (directory (file-name-directory file))
         (basename (file-name-nondirectory file))
         (buffer (current-buffer)))
    (condition-case nil
        (progn
          (unless (file-directory-p directory)
            (make-directory directory t))
          (file-notify-add-watch
           directory '(change)
           (lambda (event)
             (when (and (memq (nth 1 event) '(created changed renamed))
                        (equal (file-name-nondirectory (nth 2 event)) basename)
                        (buffer-live-p buffer))
               (with-current-buffer buffer
                 (tincan--set-state 'needs-input))))))
      (error nil))))

;; ** Watching a session
(defun tincan--filter (proc chunk)
  "Insert CHUNK from PROC at its process mark; follow the tail and track state."
  (let ((buffer (process-buffer proc)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let* ((mark (process-mark proc))
               (old (marker-position mark))
               (inhibit-read-only t))
          (save-excursion
            (goto-char mark)
            (insert chunk)
            (set-marker mark (point)))
          (tincan--scan-for-state mark)
          (tincan--autofold)
          ;; Follow the tail in any window that was already at the end.
          (dolist (window (get-buffer-window-list buffer nil t))
            (when (>= (window-point window) old)
              (set-window-point window (point-max)))))))))

(defun tincan--sentinel (proc event)
  "Report when the tincan follower PROC ends (EVENT)."
  (let ((buffer (process-buffer proc)))
    (when (and (buffer-live-p buffer) (not (process-live-p proc)))
      (with-current-buffer buffer
        (message "tincan: follower for %s exited (%s)"
                 tincan--session-id (string-trim event))))))

(defun tincan--cleanup ()
  "Tear down this buffer's follower process and notify watch.
For `kill-buffer-hook'."
  (when (process-live-p tincan--process)
    (delete-process tincan--process))
  (when tincan--notify-watch
    (file-notify-rm-watch tincan--notify-watch)
    (setq tincan--notify-watch nil)))

(defun tincan--session-buffer (session)
  "Return an existing tincan buffer bound to SESSION, or nil."
  (seq-find (lambda (buffer)
              (equal (buffer-local-value 'tincan--session-id buffer) session))
            (buffer-list)))

(defun tincan--watch (session buffer-name)
  "Set up a buffer watching SESSION (an id or transcript path); return it.
Reuse the buffer already bound to SESSION - matched by id, not name, since the
title (hence the name) can change; BUFFER-NAME names a freshly created one."
  (let ((existing (tincan--session-buffer session)))
    (if (and existing
             (process-live-p (buffer-local-value 'tincan--process existing)))
        existing
      (let ((buffer (or existing (generate-new-buffer buffer-name))))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer))
          (tincan-render-buffer)
          (setq-local tincan--session-id session)
          (setq-local tincan--scan-marker (copy-marker (point-min)))
          (tincan--set-state 'working)
          (add-hook 'kill-buffer-hook #'tincan--cleanup nil t)
          (let ((proc (make-process
                       :name (format "tincan-%s" session)
                       :buffer buffer
                       :command (list "python3" tincan-script session "--follow")
                       :connection-type 'pipe
                       :filter #'tincan--filter
                       :sentinel #'tincan--sentinel
                       :noquery t)))
            (setq-local tincan--process proc)
            (set-marker (process-mark proc) (point-max)))
          (setq-local tincan--notify-watch (tincan--setup-notify-watch session)))
        buffer))))

;;;###autoload
(defun tincan (session-id &optional title)
  "Watch a Claude Code SESSION-ID live in a read-only buffer.
TITLE, if given, is shown (abbreviated) in the buffer name.
Interactively, choose among this project's sessions."
  (interactive (let ((choice (tincan--read-session)))
                 (list (car choice) (cdr choice))))
  (pop-to-buffer
   (tincan--watch session-id (tincan--buffer-name session-id title))))

;; * Footer
(provide 'tincan)
;;; tincan.el ends here
