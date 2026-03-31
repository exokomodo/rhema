#!/usr/bin/env bash
# sbcl-repl.sh — Manage a persistent SBCL background REPL for Rhema
#
# Usage:
#   sbcl-repl.sh start      — start SBCL in background (PTY via exec is handled by the skill)
#   sbcl-repl.sh status     — check if session file exists and process is alive
#   sbcl-repl.sh session-id — print the stored session ID
#   sbcl-repl.sh init-path  — print the path to init.lisp
#   sbcl-repl.sh library-dir — print the library directory path

set -euo pipefail

RHEMA_DIR="${RHEMA_DIR:-$HOME/rhema}"
SESSION_FILE="$RHEMA_DIR/.sbcl-session"
INIT_FILE="$RHEMA_DIR/init.lisp"
LIBRARY_DIR="$RHEMA_DIR/library"
SBCL_PID_FILE="$RHEMA_DIR/.sbcl-pid"

ensure_dirs() {
    mkdir -p "$RHEMA_DIR" "$LIBRARY_DIR"
    # Bootstrap library files from repo if not already present
    local repo_library
    repo_library="$(dirname "$0")/../library"
    if [ -d "$repo_library" ]; then
        for f in "$repo_library"/*.lisp; do
            [ -f "$f" ] || continue
            local dest="$LIBRARY_DIR/$(basename "$f")"
            if [ ! -f "$dest" ]; then
                cp "$f" "$dest"
            fi
        done
    fi
}

generate_init() {
    # Render init.lisp from scripts/init.lisp.template
    ensure_dirs
    local template
    template="$(dirname "$0")/init.lisp.template"

    # Build library load lines
    local library_loads=""
    if [ -d "$LIBRARY_DIR" ]; then
        for f in "$LIBRARY_DIR"/*.lisp; do
            [ -f "$f" ] || continue
            library_loads="${library_loads}(load \"$f\")
"
        done
    fi
    # Strip trailing newline
    library_loads="${library_loads%$'\n'}"

    if [ -f "$template" ]; then
        # Render template: substitute {{LIBRARY_LOADS}} and {{HOME}}
        sed \
            -e "s|{{HOME}}|$HOME|g" \
            -e "s|{{LIBRARY_LOADS}}|${library_loads}|g" \
            "$template" > "$INIT_FILE"
    else
        # Fallback: inline generation if template missing
        {
            echo ";;;; Rhema init.lisp — auto-generated (template not found)"
            echo "${library_loads}"
            echo "(load \"$HOME/quicklisp/setup.lisp\")"
            echo "(ql:quickload :swank :silent t)"
            echo "(swank:create-server :port 4005 :dont-close t)"
            echo "(rhema-server:start)"
        } > "$INIT_FILE"
    fi
    echo "$INIT_FILE"
}

store_session() {
    local session_id="$1"
    local pid="$2"
    ensure_dirs
    echo "$session_id" > "$SESSION_FILE"
    echo "$pid" > "$SBCL_PID_FILE"
}

get_session_id() {
    if [ -f "$SESSION_FILE" ]; then
        cat "$SESSION_FILE"
    else
        echo ""
    fi
}

get_pid() {
    if [ -f "$SBCL_PID_FILE" ]; then
        cat "$SBCL_PID_FILE"
    else
        echo ""
    fi
}

check_alive() {
    local pid
    pid=$(get_pid)
    if [ -z "$pid" ]; then
        echo "dead"
        return
    fi
    if kill -0 "$pid" 2>/dev/null; then
        echo "alive"
    else
        echo "dead"
    fi
}

cmd="${1:-status}"

case "$cmd" in
    ensure-dirs)
        ensure_dirs
        ;;
    generate-init)
        generate_init
        ;;
    store-session)
        store_session "${2:-}" "${3:-}"
        ;;
    session-id)
        get_session_id
        ;;
    pid)
        get_pid
        ;;
    status)
        state=$(check_alive)
        session_id=$(get_session_id)
        echo "status=$state session=$session_id"
        ;;
    init-path)
        generate_init >/dev/null
        echo "$INIT_FILE"
        ;;
    library-dir)
        echo "$LIBRARY_DIR"
        ;;
    rhema-dir)
        echo "$RHEMA_DIR"
        ;;
    *)
        echo "Unknown command: $cmd" >&2
        exit 1
        ;;
esac
