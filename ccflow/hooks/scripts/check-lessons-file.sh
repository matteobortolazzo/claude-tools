#!/bin/sh
# Verify ccflow is configured. The presence of .claude/config.json — not lessons-learned.md —
# is the real signal: lessons-learned.md is now optional (last-resort dump for cross-cutting
# mistakes; most lessons should land in topic-specific rule files or CLAUDE.md instead).
test -f .claude/config.json || echo 'WARNING: .claude/config.json not found. Run /ccflow:configure to set up.'
