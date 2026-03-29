---
name: rhema
description: "Persistent Common Lisp REPL shared across all agent sessions via Unix socket. Use this skill whenever you need to evaluate, run, or execute any Common Lisp (CL) code. Do NOT start a standalone sbcl process — always route through the Rhema socket at /tmp/rhema.sock."
---

# Rhema Skill — Persistent Common Lisp REPL

## ⚠️ The Socket is Shared State

`/tmp/rhema.sock` is a **single shared REPL** running on this machine. Every
agent, every Discord channel, every session connects to the same SBCL process
and the same Lisp image. This is intentional.

**What this means:**
- A function defined in one channel is available in all other channels
- State accumulates across all sessions — nobody has a private REPL
- If another agent or channel redefined something you defined, your definition is gone
- Library files (`~/rhema/library/`) are the durable layer — in-memory state is shared and volatile

**Always use the socket** unless you have a specific reason to use a private PTY session.

---

## Quick Start

Check if the socket is up:

```bash
ls /tmp/rhema.sock 2>/dev/null && echo "UP" || echo "DOWN"
```

Eval any expression:

```bash
echo '(+ 1 2)' | socat - UNIX-CONNECT:/tmp/rhema.sock
```

Result comes back pre-delimited — no wrapping needed:

```
===RHEMA-BEGIN===
3
===RHEMA-END===
```

---

## Starting the REPL (if socket is down)

Start SBCL with the socket server as a background PTY session:

```
exec: sbcl --noinform --disable-debugger --load /home/butler/rhema/init.lisp
pty: true
background: true
```

Store the session ID for health checks:

```bash
~/github.com/exokomodo/rhema/scripts/sbcl-repl.sh store-session <session-id> <pid>
```

The socket server auto-starts from `init.lisp`. Once up, all agents use the
socket — not the PTY session directly.

---

## Checking / Reattaching the PTY Session

```bash
~/github.com/exokomodo/rhema/scripts/sbcl-repl.sh status
# => status=alive session=<id>
# => status=dead session=
```

If alive, get the session ID:

```bash
session_id=$(~/github.com/exokomodo/rhema/scripts/sbcl-repl.sh session-id)
```

If session ID is stale, scan running sessions:

```
process(action=list)
```

Find the entry running `sbcl`, re-store it:

```bash
~/github.com/exokomodo/rhema/scripts/sbcl-repl.sh store-session <found-id> <pid>
```

---

## Evaluating via Socket (preferred)

```bash
echo '(your-expression)' | socat - UNIX-CONNECT:/tmp/rhema.sock
```

Extract text between `===RHEMA-BEGIN===` and `===RHEMA-END===`. Done.

**No wrapping needed** — the socket server applies delimiters and error handling
server-side.

---

## Evaluating via PTY (fallback / private)

Use only if the socket is down or you need a private REPL isolated from shared state.

Wrap the expression and send via PTY:

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

**Use `(error ...)` not `(condition ...)`** — `condition` catches warnings,
which causes SBCL redefine warnings to abort eval before the new definition
lands. Muffle warnings explicitly with `handler-bind`.

Poll for results:

```
process(action=poll, sessionId=<id>, timeout=15000)
```

---

## Defining and Saving Functions

**Define in the shared REPL:**

```bash
echo '(defun greet (name) (format nil "Hello, ~A!" name))' | socat - UNIX-CONNECT:/tmp/rhema.sock
```

**Verify:**

```bash
echo '(greet "World")' | socat - UNIX-CONNECT:/tmp/rhema.sock
```

**Save to library** (survives SBCL restarts, auto-loads on init):

```bash
cat > /home/butler/rhema/library/utils.lisp << 'EOF'
(defun greet (name)
  (format nil "Hello, ~A!" name))
EOF

# Regenerate init.lisp
~/github.com/exokomodo/rhema/scripts/sbcl-repl.sh generate-init

# Load immediately into running REPL
echo '(load "/home/butler/rhema/library/utils.lisp")' | socat - UNIX-CONNECT:/tmp/rhema.sock
```

---

## Library Directory

```
~/rhema/
├── init.lisp              ← auto-generated; loads library/ + starts socket server
└── library/
    ├── server.lisp        ← socket server (do not remove)
    ├── core.lisp          ← general utilities
    ├── http.lisp          ← HTTP helpers
    └── ...
```

List saved files:

```bash
ls -la /home/butler/rhema/library/
```

---

## Bootstrapping Quicklisp (first time only)

```bash
ls ~/quicklisp/setup.lisp 2>/dev/null || echo "not installed"
```

If not installed, eval in the REPL:

```lisp
(progn
  (sb-ext:run-program "/usr/bin/curl"
    (list "-o" "/tmp/quicklisp.lisp" "https://beta.quicklisp.org/quicklisp.lisp")
    :output *standard-output*)
  (load "/tmp/quicklisp.lisp")
  (funcall (find-symbol "INSTALL" "QUICKLISP-QUICKSTART")
           :path (merge-pathnames "quicklisp/" (user-homedir-pathname))))
```

Then prepend to `~/rhema/init.lisp`:

```lisp
(load "~/quicklisp/setup.lisp")
```

Common packages:
- `:dexador` — HTTP client
- `:jonathan` or `:cl-json` — JSON
- `:cl-ppcre` — regex
- `:uiop` — filesystem, processes (included with ASDF)
- `:local-time` — date/time

---

## Error Reference

| Output | Meaning | Action |
|--------|---------|--------|
| `ERROR: <text>` | Handled Lisp error | Read and fix |
| No `===RHEMA-END===` after timeout | Infinite loop or hang | Kill PTY session, restart SBCL |
| Socket connection refused | REPL is down | Start SBCL (see above) |
| Function undefined | Defined in another session but not saved to library | Redefine or `load` the library file |

## Timeout Guard

```lisp
(sb-ext:with-timeout 10
  (your-expression))
```

Signals `sb-ext:timeout` after 10 seconds — caught by the server's error handler
and returned as `ERROR: Timeout`.
