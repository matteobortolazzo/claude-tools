#!/bin/sh
# Check if per-project lessons files exist for monorepo projects
if test -f .claude/config.json && grep -q '"isMonorepo".*true' .claude/config.json 2>/dev/null; then
  missing=''
  for slug in $(grep -o '"slug"[[:space:]]*:[[:space:]]*"[^"]*"' .claude/config.json | sed 's/.*"\([^"]*\)"$/\1/'); do
    test -f ".claude/rules/lessons-learned-${slug}.md" || missing="${missing} lessons-learned-${slug}.md"
  done
  if [ -n "$missing" ]; then
    echo "WARNING: Missing per-project lessons files:${missing}. Run /ccflow:configure to regenerate."
  else
    echo 'All per-project lessons files found'
  fi
fi
