# Dev Sandbox (claude-sand)

Isolated Docker/Podman container for running Claude Code with full permissions. Your host OS stays clean — only `~/Repos` is shared with the container.

## Prerequisites

- Docker or Podman installed on the host
- Claude Code installed on the host (`claude` in PATH)
- Host user UID must be 1000 (standard Linux default)

## Setup

```bash
# Symlink the launcher to your PATH
ln -s "$(pwd)/dev-sandbox/claude-sand" ~/.local/bin/claude-sand

# Build the image
claude-sand --build
```

## Usage

```bash
# Launch Claude Code (all tools pre-approved, no permission prompts)
claude-sand

# Pass additional args to Claude Code
claude-sand -p "fix the tests"
claude-sand --model sonnet

# Open a bash shell for manual setup / troubleshooting
claude-sand --shell

# Run a named instance (separate home volume)
claude-sand --name myproject

# Rebuild the image (after changing Dockerfile or SDK versions)
claude-sand --build
```

The container starts in the directory matching your host `$PWD` (mapped through `~/Repos` → `/workspace`).

If a container with the same name is already running, the script attaches to it instead of creating a new one.

## First-Run Setup

On first launch, open a shell and set up your environment:

```bash
claude-sand --shell

# Inside the container:
gh auth login              # GitHub CLI auth
claude                     # Claude Code auth (first launch)
claude plugin install ...  # Install any plugins you need
```

Everything persists in the home volume — only needs to happen once per instance.

## What's Included

| Tool | Version | Build arg override |
|------|---------|-------------------|
| .NET SDK | 10.0.100 | `DOTNET_SDK_VERSION` |
| Node.js | 24.x | `NODE_MAJOR` |
| Go | 1.24.1 | `GO_VERSION` |
| GitHub CLI | latest | — |
| git, ripgrep, jq, curl | latest | — |
| build-essential | latest | — |
| Python 3 | latest | — |

Override versions at build time:

```bash
docker build --build-arg DOTNET_SDK_VERSION=10.0.200 \
             --build-arg GO_VERSION=1.25.0 \
             -t claude-sandbox:latest dev-sandbox/
```

## Architecture

### Isolation

- Container has its **own home directory** (`/home/dev`) backed by a named Docker volume
- Only `~/Repos` from the host is mounted at `/workspace`
- Outbound network only (no inbound ports published)

### What persists (home volume)

| Path | Contents |
|------|----------|
| `/home/dev/.claude/` | Claude Code config, plugins, session data |
| `/home/dev/.npm/` | npm package cache |
| `/home/dev/.nuget/` | NuGet package cache |
| `/home/dev/.dotnet/` | .NET user-level config |
| `/home/dev/go/` | Go modules and build cache |
| `/home/dev/.config/gh/` | GitHub CLI auth token |
| `/home/dev/.bash_history` | Shell history |

### What's bind-mounted read-only

| Host path | Container path | Purpose |
|-----------|---------------|---------|
| Claude binary | `/usr/local/bin/claude` | Always matches host version |
| `~/.config/git/config` or `~/.gitconfig` | `/home/dev/.gitconfig` | Git identity |

### Muxwatch (optional)

If `muxwatch` is installed on the host and the daemon is running, the script automatically:
- Bind-mounts the `muxwatch` binary (read-only)
- Bind-mounts the events socket so hooks can reach the host daemon
- Passes `$TMUX_PANE` for tmux window status updates

Install the muxwatch plugin inside the container: `claude plugin install muxwatch`

### Container lifecycle

- Containers are created with `--rm` — removed automatically on exit
- The home volume survives container removal
- Each `--name` instance gets its own container and volume

## Maintenance

### Update SDK versions

Edit the `ARG` lines at the top of the `Dockerfile`, then rebuild:

```bash
claude-sand --build
```

### Update Claude Code

Just update Claude Code on the host. The binary is bind-mounted, so the container always uses the host version.

### Reset an instance

Delete the home volume to start fresh (caches, auth, config all cleared):

```bash
docker volume rm claude-sand-home-default
# or for a named instance:
docker volume rm claude-sand-home-myproject
```

### List instances

```bash
docker volume ls --filter name=claude-sand-home
```

### Clean up everything

```bash
# Remove all sandbox volumes
docker volume ls --filter name=claude-sand-home -q | xargs docker volume rm

# Remove the image
docker rmi claude-sandbox:latest
```

## Sharing the Image

### Via container registry

```bash
docker tag claude-sandbox:latest ghcr.io/YOUR_ORG/claude-sandbox:latest
docker push ghcr.io/YOUR_ORG/claude-sandbox:latest
```

Recipients pull the image and only need the `claude-sand` script.

### Via file export

```bash
# Export
docker save claude-sandbox:latest | gzip > claude-sandbox.tar.gz

# Import on another machine
docker load < claude-sandbox.tar.gz
```

## Troubleshooting

**Permission errors on `/workspace` files**
Your host UID must be 1000. Check with `id -u`.

**`claude` binary not found**
Ensure `claude` is in your host PATH. Check with: `readlink -f "$(which claude)"`

**Container runtime**
The script auto-detects `podman` first, then falls back to `docker`.
