# Rhema — Design Document

## Overview

Rhema embeds large language models inside a persistent Common Lisp REPL. The
model evaluates expressions, defines functions, evolves its own tool library
across sessions, and uses the REPL as external memory and computation — not as a
code-generation target, but as a living environment.

This document describes the phased implementation plan, architectural decisions,
and open questions.

### Reference

> de la Torre, J. (2025). *From Tool Calling to Symbolic Thinking: LLMs in a
> Persistent Lisp Metaprogramming Loop.* arXiv
> [2506.10021v1](https://arxiv.org/abs/2506.10021v1).

The paper proposes the architecture and design principles. Rhema is the
implementation.

---

## Phase 1 — Persistent REPL Skill

**Goal:** A working agent ↔ Lisp loop with zero changes to OpenClaw core.

**Estimated effort:** 1–2 days.

### Architecture

```
┌──────────────────────────────────────┐
│            OpenClaw Agent            │
│                                      │
│  ┌────────────┐   ┌──────────────┐   │
│  │  SKILL.md  │   │  Agent LLM   │   │
│  │  (Rhema)   │──▶│  (Sonnet/    │   │
│  │            │   │   Opus/etc)  │   │
│  └────────────┘   └──────┬───────┘   │
│                          │           │
│                     eval │ read      │
│                          │           │
│                   ┌──────▼───────┐   │
│                   │  Background  │   │
│                   │  SBCL REPL   │   │
│                   │  (persistent)│   │
│                   └──────┬───────┘   │
│                          │           │
│                   ┌──────▼───────┐   │
│                   │  ~/rhema/    │   │
│                   │  library/    │   │
│                   │  (agent's    │   │
│                   │   functions) │   │
│                   └──────────────┘   │
└──────────────────────────────────────┘
```

### Components

#### 1. Background SBCL Process

A persistent SBCL instance managed as a background `exec` session. The skill
starts it on first use and reattaches on subsequent invocations.

- **Implementation:** SBCL via Steel Bank Common Lisp — fastest CL compiler,
  most production-ready, widely available on Linux/macOS/arm64.
- **Lifecycle:** Starts on first `(eval ...)` call. Persists across agent turns.
  Restarts automatically if killed.
- **Quicklisp:** Loaded at startup. Too much wheel-reinvention without it —
  HTTP (`dexador`), JSON (`jonathan`/`cl-json`), regex (`cl-ppcre`), and
  filesystem utilities are table stakes.

#### 2. Delimiter-Based Result Extraction

SBCL's output format is complex — multiple return values, debugger output,
compiler notes, warnings. Parsing it reliably is fragile.

Instead, we wrap every evaluation:

```lisp
(progn
  (format t "~%===RHEMA-BEGIN===~%")
  (let ((result (progn <user-expression>)))
    (format t "~A" result)
    (format t "~%===RHEMA-END===~%")
    result))
```

The skill extracts text between `===RHEMA-BEGIN===` and `===RHEMA-END===`
delimiters. This cleanly separates results from compiler noise, debugger
prompts, and side-effect output.

**Side-effect output** (anything printed by the evaluated expression) appears
before `===RHEMA-BEGIN===` and is captured separately for the agent to inspect.

#### 3. Agent Library (`~/rhema/library/`)

The agent maintains its own function library on disk:

```
~/rhema/
├── library/
│   ├── core.lisp        # always-loaded utilities
│   ├── http.lisp        # HTTP helper functions
│   ├── text.lisp        # string manipulation tools
│   └── ...
├── init.lisp            # startup file, loads library
└── state.lisp           # serialized session state (optional)
```

- **Auto-load on startup:** `init.lisp` loads all library files when SBCL
  starts. The agent never loses its tools between sessions.
- **Agent-managed:** The agent decides what to save, how to organize it, and
  when to refactor. This is the core design principle — self-directed tool
  evolution, not human-curated tool sets.
- **Version control:** The library directory can be committed to a repo for
  history and sharing.

#### 4. Skill Interface

The skill exposes these operations to the agent:

| Operation | Description |
|-----------|-------------|
| `eval <expr>` | Evaluate a Lisp expression in the persistent REPL |
| `load <file>` | Load a `.lisp` file into the REPL |
| `save <name> <code>` | Write a function/macro to the library |
| `library` | List saved library files |
| `restart` | Kill and restart the SBCL process |
| `status` | Check if the REPL is alive, uptime, loaded packages |

All operations go through the same background SBCL process. State accumulates
across calls.

### Security Model

**Same trust boundary as `exec`.** The REPL can do anything the shell can —
file I/O, network access, process spawning. No new security surface is
introduced. The existing OpenClaw exec policy (approval prompts for elevated
commands, sandbox restrictions) applies identically.

Quicklisp package installation follows the same model: if the agent can `apt
install` or `pip install`, it can `(ql:quickload ...)`.

### Example Session

```
Agent: I need to fetch JSON from an API and extract a field.

[eval] (ql:quickload :dexador :cl-json)
=> T

[eval] (defun fetch-json (url)
         (cl-json:decode-json-from-string
           (dex:get url)))
=> FETCH-JSON

[save http.lisp]  ; persists fetch-json to library

[eval] (fetch-json "https://api.example.com/status")
=> ((:STATUS . "ok") (:VERSION . "2.1.0"))

; Next session — function auto-loads from library
[eval] (fetch-json "https://api.example.com/status")
=> ((:STATUS . "ok") (:VERSION . "2.1.1"))
```

---

## Phase 2 — MCP Server

**Goal:** Expose the Rhema REPL as a first-class tool in any MCP-compatible
host — the LLM calls `rhema_eval` during its reasoning loop, not as an
afterthought.

**Requires:** A small MCP stdio server. No changes to OpenClaw core or opencode.

### Why MCP over stream interception

The original Phase 2 design proposed mid-generation `<lisp>` tag interception —
a plugin that buffers and rewrites the LLM's token stream. This was discarded
for the following reasons:

- Requires invasive plugin hooks into each host's streaming pipeline
- Each host (OpenClaw, opencode, Claude Desktop, Cursor) needs separate work
- High latency risk mid-stream; complex error handling
- Models aren't trained to emit `<lisp>` tags; effectiveness is unreliable

An MCP server achieves the same goal — Lisp in the reasoning loop — via the
standard tool-use protocol that every major LLM host already supports.

### Architecture

```
┌──────────────────────────────────────┐
│         LLM Host (any)               │
│  (OpenClaw / opencode / Cursor / ...) │
│                                      │
│  ┌──────────────┐                    │
│  │  Agent LLM   │                    │
│  │              │──── rhema_eval ───▶│──┐
│  │              │◀─── result ────────│  │
│  └──────────────┘                    │  │
└──────────────────────────────────────┘  │
                                          │
                           ┌──────────────▼──────────┐
                           │   Rhema MCP Server       │
                           │   (stdio, local process)  │
                           └──────────────┬───────────┘
                                          │ socat
                                          │
                           ┌──────────────▼───────────┐
                           │  /tmp/rhema.sock           │
                           │  (persistent SBCL REPL)    │
                           └───────────────────────────┘
```

### Tool surface

Single tool: `rhema_eval`

```json
{
  "name": "rhema_eval",
  "description": "Evaluate a Common Lisp expression in the persistent Rhema REPL. State is shared across all sessions on this machine. Returns the result as a string.",
  "parameters": {
    "type": "object",
    "properties": {
      "expression": {
        "type": "string",
        "description": "Common Lisp expression to evaluate"
      }
    },
    "required": ["expression"]
  }
}
```

The server implementation delegates to the Unix socket:
`echo '(expr)' | socat - UNIX-CONNECT:/tmp/rhema.sock`

If the socket is down, the server starts SBCL with `init.lisp` automatically,
then retries.

### Host configuration

Both OpenClaw and opencode use the same config format:

```json
{
  "mcp": {
    "rhema": {
      "type": "local",
      "command": ["/path/to/rhema-mcp-server"],
      "enabled": true
    }
  }
}
```

Any other MCP-compatible host (Claude Desktop, Cursor, etc.) works identically.

### Implementation plan

1. `mcp/server.ts` — MCP stdio server (Node/TypeScript, minimal dependencies)
2. Expose `rhema_eval` — delegates to socket, handles socket-down restart
3. `make build/mcp` — builds/bundles the server binary
4. `make install/mcp` — installs to `~/.local/bin/rhema-mcp-server`
5. Document config snippets for OpenClaw and opencode in SKILL.md and README

### Why TypeScript for the MCP server?

The MCP SDK has the best TypeScript support (`@modelcontextprotocol/sdk`).
The server itself is trivial — connect to socket, forward expression, return
result. Runtime size is not a concern for a local stdio process.

### Original stream interception design (archived)

The original Phase 2 design (mid-generation `<lisp>` tag interception) is
preserved in `docs/archive/phase2-stream-interception.md` for reference.
It remains theoretically interesting — computation woven directly into
generation rather than between turns — but the MCP approach delivers the
practical benefit without the engineering cost.

Issues #8, #9, #10 are deprioritized in favor of #22 (this work).

---

## Phase 3 — Community Packaging

**Goal:** Multi-dialect support and library sharing.

### Multi-Dialect Support

The persistent REPL architecture isn't CL-specific. Phase 3 extends to:

| Dialect | Runtime | Notes |
|---------|---------|-------|
| Common Lisp | SBCL | Primary, Phase 1 |
| Clojure | Babashka | Fast startup, no JVM, good for scripting |
| Scheme | Guile | GNU ecosystem, good FFI, lightweight |

Each dialect gets its own skill variant with the same interface (eval, save,
load, library). The agent chooses the dialect that fits the task — or uses
multiple simultaneously.

### Library Sharing

Agent-built libraries can be packaged and shared:

- **ClawHub distribution** — publish Rhema libraries as ClawHub skills/packages
  that other agents can install and extend.
- **Curated collections** — community-maintained libraries for common tasks
  (web scraping, data processing, API clients) built *by agents, for agents*.
- **Library evolution tracking** — version control + diffs show how an agent's
  tools evolved over time. Research value for understanding tool-use patterns.

### Trust Model for Shared Libraries

Shared libraries are code. Same trust model as any ClawHub skill — the agent
(or user) decides whether to load third-party code. No auto-execution of
untrusted libraries.

---

## Design Decisions

### Why SBCL?

| Criterion | SBCL | CCL | ECL | CLISP |
|-----------|------|-----|-----|-------|
| Compilation speed | Fastest | Good | Slow | Interpreted |
| Runtime performance | Best | Good | Good (via C) | Slow |
| arm64 support | Yes | Yes | Yes | Yes |
| Quicklisp compat | Full | Full | Partial | Full |
| Production use | Extensive | Moderate | Niche | Hobbyist |
| REPL quality | Excellent | Good | Basic | Good |

SBCL is the clear choice for Phase 1. Other implementations can be added in
Phase 3 if needed.

### Why Quicklisp from day one?

Without Quicklisp, the agent would need to implement HTTP clients, JSON
parsers, regex engines, and filesystem utilities from scratch — or do everything
through shell exec calls, defeating the purpose of living in Lisp.

Quicklisp makes the REPL immediately useful for real-world tasks. The agent can
`(ql:quickload :dexador)` and start making HTTP requests in its first session.

### Why delimiter-based extraction over output parsing?

SBCL output includes:

- Multiple return values
- Compiler notes and warnings
- Debugger prompts on errors
- Side-effect output interleaved with return values
- Package prefixes that change based on `*package*`

Reliable parsing of all these formats is fragile and implementation-specific.
Delimiters are simple, robust, and work regardless of SBCL's output
configuration.

### Why agent-managed libraries over human-curated ones?

The paper's thesis is that LLMs can engage in *self-directed tool evolution* —
defining, refining, and composing tools based on experience. Human curation
short-circuits this process. The agent should discover what tools it needs and
build them.

Human intervention is still possible (editing library files, suggesting
directions), but the default is agent autonomy.

---

## Open Questions

### 1. MCP server language choice

TypeScript (`@modelcontextprotocol/sdk`) has the best MCP support and the
server logic is trivial. Go is also viable if we want a single static binary
with no Node runtime dependency.

**Current decision:** TypeScript. Can be revisited if distribution complexity
is a concern.

### 2. State serialization between sessions

The REPL's in-memory state (defined functions, global variables, loaded
packages) is lost if the process restarts. The library auto-load handles
*functions*, but what about runtime state?

Options:

- **Serialize explicitly** — agent saves state to `state.lisp` before shutdown
- **Image dumping** — SBCL can dump a core image, but these are large and
  platform-specific
- **Accept ephemeral state** — only library functions persist; runtime state is
  rebuilt on startup

### 3. Multi-agent REPL sharing

Can multiple agents share a single REPL? Or should each agent get its own
isolated instance? Shared REPLs enable collaboration but introduce state
conflicts. Isolated instances are simpler but duplicate work.

### 4. Error recovery

When the REPL hits a debugger prompt (unhandled condition), the skill needs to:

1. Detect the debugger state
2. Extract the error message
3. Abort cleanly (invoke restart)
4. Report the error to the agent

This needs to be robust — a stuck debugger prompt blocks all further evaluation.

### 5. Resource limits

A runaway `(loop)` or memory-hungry computation could consume the host. Options:

- SBCL's `sb-ext:with-timeout` for CPU limits
- `ulimit` on the SBCL process for memory
- Watchdog timer in the skill that kills and restarts stuck processes

---

## Milestones

- [ ] **M1:** SBCL background process management (start, stop, health check)
- [ ] **M2:** Delimiter-based eval with result extraction
- [ ] **M3:** Library save/load with auto-initialization
- [ ] **M4:** OpenClaw skill packaging (SKILL.md + scripts)
- [ ] **M5:** Agent self-test (agent builds and uses its own tools end-to-end)
- [ ] **M6:** MCP server (`rhema_eval` tool, opencode + OpenClaw integration)
- [ ] **M7:** Multi-dialect support (Babashka, Guile)
- [ ] **M8:** ClawHub packaging and distribution
