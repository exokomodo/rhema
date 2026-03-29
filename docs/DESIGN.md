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

## Phase 2 — Generation Interception (OpenClaw Plugin)

**Goal:** Mid-generation `<lisp>` tag interception — the full paper vision.

**Requires:** New plugin API surface in OpenClaw core.

### Concept

Instead of the agent deciding to "call a tool" (eval Lisp), the model embeds
Lisp expressions *inline during generation*:

```
The current server status is <lisp>(fetch-json "https://...")</lisp> which
indicates everything is operational.
```

A middleware layer intercepts `<lisp>` tags during token streaming, evaluates
them in the persistent REPL, and injects the results back into the generation
stream. The model never "pauses to use a tool" — computation is woven into
natural language output.

### Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────┐
│  LLM API    │────▶│  Rhema Plugin    │────▶│  Agent /     │
│  (streaming)│     │  (intercepts     │     │  User        │
│             │◀────│   <lisp> tags,   │◀────│              │
│             │     │   evals in REPL) │     │              │
└─────────────┘     └────────┬─────────┘     └──────────────┘
                             │
                      ┌──────▼───────┐
                      │  Persistent  │
                      │  SBCL REPL   │
                      └──────────────┘
```

### Requirements from OpenClaw Core

1. **Stream interception hook** — plugin can inspect and modify tokens as they
   stream from the LLM provider before reaching the agent/user.
2. **Buffering** — tokens must be bufferable so partial `<lisp>` tags can be
   accumulated before deciding whether to intercept.
3. **Injection** — evaluated results must be injectable back into the stream
   (replacing the `<lisp>...</lisp>` block) seamlessly.
4. **Error handling** — REPL errors must be injected as visible error text, not
   silently swallowed. The model should see its mistakes.

### Challenges

- **Latency:** REPL evaluation adds latency mid-stream. Fast expressions
  (lookups, arithmetic) are fine. Slow expressions (HTTP calls) may cause
  noticeable pauses. May need async evaluation with placeholder tokens.
- **Nesting:** Can a `<lisp>` result contain further `<lisp>` tags? Probably
  not in Phase 2 — single-pass evaluation only.
- **Model training:** Models aren't trained to emit `<lisp>` tags. This relies
  on system prompt instruction. Effectiveness will vary by model. May need
  fine-tuning or few-shot examples in the system prompt.
- **Token counting:** Injected results affect context window accounting. The
  plugin must update token counts accurately.

### Phase 2 vs Phase 1

Phase 1's eval-and-incorporate loop is explicit: the agent decides to evaluate
Lisp, reads the result, and incorporates it into its next response. This is
**already powerful** — it's how humans use REPLs.

Phase 2's generation interception is implicit: computation happens *during*
thought, not between thoughts. This is more elegant but significantly more
complex. The open question is whether the marginal benefit justifies the
engineering cost and the new plugin API surface in OpenClaw.

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

### 1. Is Phase 2 worth the complexity?

The eval-and-incorporate loop (Phase 1) already gives the agent full access to
persistent Lisp computation. Phase 2's generation interception is more elegant
but requires:

- New OpenClaw plugin API surface
- Stream buffering and injection infrastructure
- Careful latency management
- Model-specific prompt engineering for `<lisp>` tag emission

**Question for the team:** Is the seamlessness of mid-generation evaluation
worth the engineering cost? Or is explicit eval good enough?

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
- [ ] **M6:** Phase 2 design RFC (if pursued)
- [ ] **M7:** Multi-dialect support (Babashka, Guile)
- [ ] **M8:** ClawHub packaging and distribution
