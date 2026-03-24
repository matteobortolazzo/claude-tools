# <project-name>

<stack> project within the <repo-name> monorepo.

## Stack
- <framework + version>
- Tests: <test-framework>

## Build & Test
```bash
<build-command>
<test-command>
```

## Conventions
- <project-specific rules populated during configure>

<!-- IF pencil.enabled AND project has designPath -->
## Design
- Design spec: `<designPath>/DESIGN.md` — screens, components, tokens for this project
- Design file: `<designPath>/<name>.pen` — open in Pencil, read with Pencil MCP tools
- Read DESIGN.md before implementing any frontend feature in this project
<!-- END IF -->

## Lessons
See `.claude/rules/lessons-learned-<slug>.md` for project-specific lessons.
