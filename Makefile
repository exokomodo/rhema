.PHONY: build/mcp

build/mcp:
	@command -v sbcl >/dev/null 2>&1 || { echo "ERROR: sbcl not found — install SBCL 2.6+"; exit 1; }
	@echo "Rhema MCP server ready (interpreted, no compilation needed)."
	@echo "Run with:  sbcl --script mcp/server.lisp"
