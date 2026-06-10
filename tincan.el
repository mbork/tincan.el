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
;; produced by tincan-tail.py.
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

;; * The tincan-tail.py script
(defconst tincan--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing tincan.el, used to locate tincan-tail.py.")

(defcustom tincan-script
  (expand-file-name "tincan-tail.py" tincan--directory)
  "Path to tincan-tail.py, the helper that prints, follows and manages sessions."
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
;; The markers below must stay in sync with tincan-tail.py's ROLE_* constants.
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
      (tincan-view-mode))))

;; * Notification hook
;; Optional integration: a Claude Code "Notification" hook runs tincan-tail.py,
;; which writes a small per-session file when Claude is waiting for input (e.g.
;; a tool-permission prompt).  All settings.json editing is done by the Python
;; script, so the installed command and its paths have a single source of truth;
;; the commands below are thin wrappers around it.  Installing is opt-in and only
;; signals "Claude wants you" - it does not handle tool selection.

(defcustom tincan-hook-settings-file nil
  "Settings file the Notification hook is installed into.
When nil, tincan-tail.py uses its own default,
\".claude/settings.local.json\" relative to the working directory."
  :type '(choice (const :tag "Script default" nil) file)
  :group 'tincan)

(defun tincan--run-hook-script (subcommand)
  "Run tincan-tail.py with SUBCOMMAND, echo its output, return its exit code."
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
  "Install tincan's Notification hook (via tincan-tail.py).
Installing is optional; tincan works without it.  The script backs up the
settings file first.  Afterwards, restart Claude Code or run /hooks so the
change is reviewed and loaded."
  (interactive)
  (tincan--run-hook-script "--install-hook"))

;;;###autoload
(defun tincan-uninstall-hook ()
  "Remove tincan's Notification hook (via tincan-tail.py)."
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
;; tincan-tail.py --follow as an async process and feeds the output into a
;; rendered, read-only buffer through a process filter.  Output may arrive in
;; arbitrary chunks (even mid-line), so the filter follows the marker idiom -
;; insert at the process mark, and process only newline-terminated lines.
(defvar-local tincan--process nil
  "The tincan-tail.py --follow process feeding the current buffer.")

(defvar-local tincan--session-id nil
  "The Claude Code session id shown in the current buffer.")

(defun tincan--short-id (session-id)
  "Return a short, buffer-name-friendly form of SESSION-ID."
  (substring session-id 0 (min 8 (length session-id))))

;; ** Session selection
(defun tincan--list-sessions ()
  "Return an alist of (DISPLAY . ID) for this project's sessions.
DISPLAY is \"TIMESTAMP  TITLE\".  Runs tincan-tail.py in `default-directory',
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
                          (nth 0 fields))
                    sessions)))
          (forward-line 1))
        (nreverse sessions)))))

(defun tincan--read-session ()
  "Prompt for one of this project's sessions and return its id."
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

(defun tincan--mode-line-string (state)
  "Return the mode-line indicator string for STATE."
  (pcase state
    ('working (propertize " [working]" 'face 'tincan-state-working))
    ('idle (propertize " [idle]" 'face 'tincan-state-idle))
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

(defun tincan--kill-process ()
  "Kill this buffer's follower process; for `kill-buffer-hook'."
  (when (process-live-p tincan--process)
    (delete-process tincan--process)))

(defun tincan--watch (session buffer-name)
  "Set up BUFFER-NAME to watch SESSION (an id or transcript path); return it.
Reuse the buffer if it is already watching with a live process."
  (let ((existing (get-buffer buffer-name)))
    (if (and existing
             (process-live-p (buffer-local-value 'tincan--process existing)))
        existing
      (let ((buffer (get-buffer-create buffer-name)))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer))
          (tincan-render-buffer)
          (setq-local tincan--session-id session)
          (setq-local tincan--scan-marker (copy-marker (point-min)))
          (tincan--set-state 'working)
          (add-hook 'kill-buffer-hook #'tincan--kill-process nil t)
          (let ((proc (make-process
                       :name (format "tincan-%s" session)
                       :buffer buffer
                       :command (list "python3" tincan-script session "--follow")
                       :connection-type 'pipe
                       :filter #'tincan--filter
                       :sentinel #'tincan--sentinel
                       :noquery t)))
            (setq-local tincan--process proc)
            (set-marker (process-mark proc) (point-max))))
        buffer))))

;;;###autoload
(defun tincan (session-id)
  "Watch a Claude Code SESSION-ID live in a read-only buffer.
Interactively, choose among this project's sessions."
  (interactive (list (tincan--read-session)))
  (pop-to-buffer
   (tincan--watch session-id
                  (format "*tincan: %s*" (tincan--short-id session-id)))))

;; * Footer
(provide 'tincan)
;;; tincan.el ends here
