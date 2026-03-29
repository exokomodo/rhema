# Rhema Skill — Persistent Common Lisp REPL

You have access to a persistent SBCL (Common Lisp) REPL that survives across
turns. Use it to evaluate expressions, define functions, and build a personal
tool library that auto-loads on startup.

## Prerequisites

- `sbcl` installed at `/usr/local/bin/sbcl` (2.6.2+)
- `~/github.com/exokomodo/rhema/scripts/sbcl-repl.sh` (management script)
- Quicklisp: bootstrap if `~/quicklisp/setup.lisp` doesn't exist

## Step 1 — Check or Start the REPL

Run the status check first:

```bash
~/github.com/exokomodo/rhema/scripts/sbcl-repl.sh status
```

Output is `status=alive session=<id>` or `status=dead session=`.

**If dead:** Start SBCL as a background PTY session:

```
exec: sbcl --noinform --disable-debugger --load /home/butler/rhema/init.lisp
pty: true
background: true
```

Note the session ID returned (e.g., `calm-willow`). Store it:

```bash
~/github.com/exokomodo/rhema/scripts/sbcl-repl.sh store-session <session-id> <pid>
```

**If alive:** Reattach using the stored session ID:

```bash
session_id=$(~/github.com/exokomodo/rhema/scripts/sbcl-repl.sh session-id)
```

Then use `process(action=write, sessionId=<session_id>)` as normal.

**If alive but session ID is missing or stale:** Scan running sessions:

```
process(action=list)
```

Look for a session running `sbcl`. Use that session ID and re-store it:

```bash
~/github.com/exokomodo/rhema/scripts/sbcl-repl.sh store-session <found-id> <pid>
```

**If truly dead:** Start a fresh SBCL session (see above).

## Step 2 — Evaluate an Expression

Every expression must be wrapped in the delimiter envelope for reliable
extraction. Send this via `process(action=write, sessionId=<id>)`:

```lisp
(progn
  (format t "~%===RHEMA-BEGIN===~%")
  (handler-case
    (let ((result (progn
                    (handler-bind ((warning #'muffle-warning))
                      YOUR-EXPRESSION-HERE))))
      (format t "~A" result))
    (error (c)
      (format t "ERROR: ~A" c)))
  (format t "~%===RHEMA-END===~%"))
```

**Important:** Use `(error ...)` not `(condition ...)` in `handler-case`. `condition`
catches warnings too — SBCL's redefine warnings will abort the eval before your
expression lands. `handler-bind` muffles warnings explicitly so they don't
interfere.

Then poll for results:

```
process(action=poll, sessionId=<id>, timeout=15000)
```

Extract text between `===RHEMA-BEGIN===` and `===RHEMA-END===`. That's your
result. Text printed *before* `===RHEMA-BEGIN===` is side-effect output —
capture it separately if relevant.

**Example — evaluate `(+ 1 2)`:**

Write:
```lisp
(progn (format t "~%===RHEMA-BEGIN===~%") (handler-case (let ((result (progn (handler-bind ((warning #'muffle-warning)) (+ 1 2))))) (format t "~A" result)) (error (c) (format t "ERROR: ~A" c))) (format t "~%===RHEMA-END===~%"))
```

Poll result:
```
===RHEMA-BEGIN===
3
===RHEMA-END===
```

## Step 3 — Define and Save Functions

**Define a function** (evaluates in the live REPL):

```lisp
(defun greet (name)
  (format nil "Hello, ~A!" name))
```

**Test it:**

```lisp
(greet "World")
```

**Save to library** (persists across restarts):

```bash
# Write the function to a library file
cat > /home/butler/rhema/library/utils.lisp << 'EOF'
(defun greet (name)
  (format nil "Hello, ~A!" name))
EOF

# Regenerate init.lisp to include the new file
~/github.com/exokomodo/rhema/scripts/sbcl-repl.sh generate-init
# Load it into the running REPL immediately
process(write): (load "/home/butler/rhema/library/utils.lisp")
```

## Step 4 — Bootstrap Quicklisp (first time only)

Check:
```bash
ls ~/quicklisp/setup.lisp 2>/dev/null || echo "not installed"
```

If not installed:
```lisp
(let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (unless (probe-file ql-setup)
    (let ((url "https://beta.quicklisp.org/quicklisp.lisp"))
      (sb-ext:run-program "/usr/bin/curl"
        (list "-o" "/tmp/quicklisp.lisp" url)
        :output *standard-output*)
      (load "/tmp/quicklisp.lisp")
      (funcall (find-symbol "INSTALL" "QUICKLISP-QUICKSTART")
               :path (merge-pathnames "quicklisp/" (user-homedir-pathname))))))
```

Then add to `init.lisp` manually:
```lisp
(load "~/quicklisp/setup.lisp")
```

## Reference — Library Directory

```
~/rhema/
├── init.lisp            ← auto-generated, loads everything in library/
└── library/
    ├── core.lisp        ← general utilities
    ├── http.lisp        ← HTTP helpers (dexador etc)
    └── ...
```

List saved files:
```bash
ls -la /home/butler/rhema/library/
```

## Reference — Error Patterns

| Output | Meaning | Action |
|--------|---------|--------|
| `ERROR: <condition>` | Handled error | Read error, fix expression |
| `===RHEMA-END===` missing after timeout | Infinite loop or hang | `process(action=kill)`, restart SBCL |
| `Debugger invoked` | `--disable-debugger` bypassed | Kill session, restart |
| `No session` error | Session ID stale | Run status check, restart if dead |

## Reference — Timeout Guard

Wrap long-running or potentially infinite expressions:

```lisp
(sb-ext:with-timeout 10
  (your-expression))
```

This signals `sb-ext:timeout` after 10 seconds, which `handler-case` catches
and returns as `ERROR: Timeout`.

## Reference — Quicklisp Usage

```lisp
; Load a library (downloads if needed)
(ql:quickload :dexador)

; List available systems
(ql:system-apropos "json")
```

Common packages:
- `:dexador` — HTTP client
- `:jonathan` or `:cl-json` — JSON
- `:cl-ppcre` — regex
- `:uiop` — filesystem, processes (included with ASDF, no load needed)
- `:local-time` — date/time
