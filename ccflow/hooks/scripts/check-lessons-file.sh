#!/bin/sh
# Check if lessons-learned.md exists in the project
test -f .claude/rules/lessons-learned.md && echo 'lessons-learned.md found' || echo 'WARNING: .claude/rules/lessons-learned.md not found. Run /ccflow:configure to set up.'
