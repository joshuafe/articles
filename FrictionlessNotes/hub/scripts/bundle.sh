#!/bin/zsh
# Bundle each edge function into one file under hub/dist/ so it can be deployed
# through the Supabase MCP tool (which takes file contents) or the CLI.
# Package imports (jsr:, npm:) stay external; the edge runtime resolves them.
set -e
cd "$(dirname "$0")/.."
mkdir -p dist
for fn in feed replan mcp sync; do
  deno bundle --platform=deno --packages=external --format=esm -o "dist/$fn.js" "supabase/functions/$fn/index.ts" 2>&1 | grep -v -E '^(Download|Warning)' || true
  printf '%s: %s bytes\n' "$fn" "$(wc -c < "dist/$fn.js" | tr -d ' ')"
done
