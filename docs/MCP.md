# Rhema MCP Server — Integration Guide

The Rhema MCP server exposes a single tool, `rhema_eval`, that evaluates
Common Lisp expressions inside a persistent SBCL REPL.  Any MCP-capable
host (VS Code Copilot, OpenCode, Claude Desktop, etc.) can use it.

```
Host  ──stdio/JSON-RPC──▶  mcp/server.lisp  ──unix socket──▶  /tmp/rhema.sock (SBCL)
```

---

## 1  Prerequisites

| Requirement | Why |
|-------------|-----|
| **SBCL 2.6+** | Runs the persistent REPL and the MCP server |
| **Quicklisp** | Provides the `jonathan` JSON library used by the MCP server |
| **`jonathan` loaded via Quicklisp** | `(ql:quickload :jonathan)` — the MCP server imports it at startup |
| **Rhema socket running** | The MCP server connects to `/tmp/rhema.sock`; without it, every call errors |

Install Quicklisp (if missing):

```bash
curl -O https://beta.quicklisp.org/quicklisp.lisp
sbcl --load quicklisp.lisp --eval '(quicklisp-quickstart:install)' --quit
```

---

## 2  Starting the Rhema socket

The SBCL background process must be running before any MCP client connects.
Full setup instructions are in [`skills/rhema/SKILL.md`](../skills/rhema/SKILL.md).

Quick start:

```bash
# Generate init.lisp (discovers library files automatically)
bash scripts/sbcl-repl.sh generate-init

# Launch SBCL in the background with the generated init
sbcl --load ~/rhema/init.lisp
```

Confirm the socket exists:

```bash
ls -l /tmp/rhema.sock
```

---

## 3  VS Code Copilot (agent mode)

Create `.vscode/mcp.json` in your project root:

```json
{
  "servers": {
    "rhema": {
      "type": "stdio",
      "command": "sbcl",
      "args": ["--script", "/absolute/path/to/rhema/mcp/server.lisp"]
    }
  }
}
```

> Replace `/absolute/path/to/rhema` with the actual path to this repo.

In VS Code:
1. Open Copilot Chat (agent mode).
2. The `rhema_eval` tool appears in the tool list.
3. Ask the model to evaluate a Lisp expression — it will call the tool.

---

## 4  OpenCode

Add to `~/.config/opencode/config.json`:

```json
{
  "mcpServers": {
    "rhema": {
      "command": "sbcl",
      "args": ["--script", "/absolute/path/to/rhema/mcp/server.lisp"]
    }
  }
}
```

Restart OpenCode.  The `rhema_eval` tool is available immediately.

---

## 5  Claude Desktop

Add to your Claude Desktop config (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "rhema": {
      "command": "sbcl",
      "args": ["--script", "/absolute/path/to/rhema/mcp/server.lisp"]
    }
  }
}
```

Config file locations:
- **macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Linux:** `~/.config/Claude/claude_desktop_config.json`
- **Windows:** `%APPDATA%\Claude\claude_desktop_config.json`

Restart Claude Desktop after editing.

---

## 6  Verify it works

In any connected host, ask the model:

> Call rhema_eval with the expression `(+ 1 1)`

Expected response: `2`

Try something stateful to confirm persistence:

> Evaluate `(defvar *counter* 0)` then `(incf *counter*)` twice.

The counter should increment across calls — the REPL state persists.

---

## 7  Troubleshooting

### Socket not running

```
Error: Failed to connect to /tmp/rhema.sock
```

The SBCL background process is not running or the socket was not created.

1. Check: `ls /tmp/rhema.sock`
2. If missing, start the REPL (see [section 2](#2--starting-the-rhema-socket)).
3. If the file exists but is stale (process died), remove it and restart:
   ```bash
   rm /tmp/rhema.sock
   sbcl --load ~/rhema/init.lisp
   ```

### Quicklisp not found

```
Package JONATHAN does not exist.
```

The MCP server loads `jonathan` via Quicklisp at startup.

1. Ensure Quicklisp is installed: `ls ~/quicklisp/setup.lisp`
2. If missing, install it (see [section 1](#1--prerequisites)).
3. Pre-load jonathan once: `sbcl --eval '(load "~/quicklisp/setup.lisp")' --eval '(ql:quickload :jonathan)' --quit`

### MCP server starts but tools don't appear

- Confirm the `--script` path is absolute and correct.
- Check the host's MCP log output for JSON parse errors.
- Run the server manually to see startup errors:
  ```bash
  sbcl --script mcp/server.lisp
  ```
  Then send a test request on stdin:
  ```json
  {"jsonrpc":"2.0","id":1,"method":"tools/list"}
  ```

### Permission denied on socket

`/tmp/rhema.sock` is created with mode `600` (owner-only).  The MCP
server must run as the same user that started the SBCL REPL.
