#!/bin/bash
# Ensure hostname resolves (suppresses sudo warnings)
sudo sh -c 'grep -q "$(hostname)" /etc/hosts || echo "127.0.0.1 $(hostname)" >> /etc/hosts'

# Fix home directory ownership (volume may be root-owned on first run)
sudo chown dev:dev /home/dev

# First-run setup for empty home volume
if [[ ! -f /home/dev/.bashrc ]]; then
    echo 'export PS1="[\[\e[36m\]sandbox\[\e[0m\]:\[\e[33m\]\w\[\e[0m\]] $ "' >> /home/dev/.bashrc
    echo 'alias ll="ls -la --color=auto"' >> /home/dev/.bashrc
fi

# ── Ensure .claude directory and settings exist ───────────────────
# The home volume may retain stale symlinks from previous runs where
# Claude Code pointed these paths at the host filesystem.  Replace any
# dangling symlink with a real directory / file so plugin installs work.

if [[ -L /home/dev/.claude ]]; then
    rm -f /home/dev/.claude
fi
mkdir -p /home/dev/.claude

if [[ -L /home/dev/.claude/settings.json ]]; then
    rm -f /home/dev/.claude/settings.json
fi
if [[ ! -f /home/dev/.claude/settings.json ]]; then
    echo '{}' > /home/dev/.claude/settings.json
fi

# ── Inject host credentials (staged read-only mounts → writable copies) ──

# Claude Code OAuth credentials
if [[ -f /tmp/host-claude-creds/.credentials.json ]]; then
    mkdir -p /home/dev/.claude
    cp /tmp/host-claude-creds/.credentials.json /home/dev/.claude/.credentials.json
    chmod 600 /home/dev/.claude/.credentials.json
fi

# GitHub CLI credentials
if [[ -f /tmp/host-gh-config/hosts.yml ]]; then
    mkdir -p /home/dev/.config/gh
    cp /tmp/host-gh-config/hosts.yml /home/dev/.config/gh/hosts.yml
    chmod 600 /home/dev/.config/gh/hosts.yml
fi

# ── Docker socket group alignment (DooD) ────────────────────────────
if [[ -S /var/run/docker.sock ]]; then
    SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
    EXISTING_GROUP=$(getent group "${SOCK_GID}" | cut -d: -f1 || true)
    if [[ -z "${EXISTING_GROUP}" ]]; then
        sudo groupadd -g "${SOCK_GID}" docker
        EXISTING_GROUP="docker"
    fi
    if ! id -nG dev | grep -qw "${EXISTING_GROUP}"; then
        sudo usermod -aG "${EXISTING_GROUP}" dev
        if [[ $# -gt 0 ]]; then
            exec sg "${EXISTING_GROUP}" -c "/bin/bash $(printf '%q ' "$@")"
        else
            exec sg "${EXISTING_GROUP}" -c /bin/bash
        fi
    fi
fi

exec /bin/bash "$@"
