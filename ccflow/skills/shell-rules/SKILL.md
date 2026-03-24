---
name: shell-rules
description: Shared shell rules for sandbox compatibility. Read before running gh CLI commands, when encountering heredoc sandbox errors, sandbox write errors, or when creating PR bodies or issue descriptions via CLI.
user-invocable: false
---

## Heredoc Temp-File Pattern

Heredocs (`cat <<'EOF'`) fail in the sandbox (read-only filesystem can't create temp files). For any `gh` command that accepts `--body` or `--description`, write the content to a temp file first, then read it back:
```bash
printf '%s' '<content>' > /tmp/claude/<descriptive-name>.md
BODY=$(cat /tmp/claude/<descriptive-name>.md)
gh issue edit <number> --body "$BODY"
```
Never run `gh issue edit` or `gh pr create` without explicit `--body`/`--title` flags — interactive mode will hang.
