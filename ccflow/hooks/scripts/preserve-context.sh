#!/bin/sh
# PreCompact hook: output key context that should survive compaction
# This ensures lessons-learned rules and pipeline state persist through context compression

echo "=== CONTEXT PRESERVATION (PreCompact) ==="

# Output lessons-learned if it exists (project-local, sandbox-safe)
if test -f .claude/rules/lessons-learned.md; then
  echo ""
  echo "## Key Lessons (from .claude/rules/lessons-learned.md):"
  # Output the last 20 entries (most recent lessons are most relevant)
  tail -100 .claude/rules/lessons-learned.md
fi

# Output any active pipeline state markers
if test -f .claude/config.json; then
  echo ""
  echo "## Active Config:"
  echo "Config exists at .claude/config.json — re-read it for ticket/PR system settings."
fi

echo ""
echo "=== END CONTEXT PRESERVATION ==="
