# Skill: github-selfhosted-runner

Provision a self-hosted GitHub Actions runner in Docker on any Linux host (WSL2, VM, bare metal). Handles image build, token refresh, and container lifecycle.

Runners live under `$GITHUB_RUNNERS_PATH` (exported in `~/.zshrc`, defaults to `/mnt/d/github-runner`). One directory per repository — a runner can be rebuilt and re-run from the same path anytime, so runners are reusable for the future.

## Usage

### Quick start

```bash
# 0. Ensure base path is set (from ~/.zshrc)
export GITHUB_RUNNERS_PATH=${GITHUB_RUNNERS_PATH:-/mnt/d/github-runner}

# 1. Create project directory
mkdir -p "$GITHUB_RUNNERS_PATH/<repo-name>" && cd "$_"

# 2. Copy template
cp -r ~/.globalskills/skills/github-selfhosted-runner/template/* .

# 3. Get a fresh token
gh api --method POST /repos/<owner>/<repo>/actions/runners/registration-token --jq '.token'

# 4. Set in docker-compose.yml (REPO_URL + RUNNER_TOKEN)

# 5. Build & start
docker compose build --no-cache && docker compose up -d

# 6. Verify
docker logs <container-name> --tail 5
```

Expected log: `Listening for Jobs` means the runner is registered and idle.

### Re-running an existing runner

If a runner already exists at `$GITHUB_RUNNERS_PATH/<repo-name>`, you only need a fresh token and a restart:

```bash
cd "$GITHUB_RUNNERS_PATH/<repo-name>"
NEW_TOKEN=$(gh api --method POST /repos/<owner>/<repo>/actions/runners/registration-token --jq '.token')
sed -i "s/RUNNER_TOKEN:.*/RUNNER_TOKEN: $NEW_TOKEN/" docker-compose.yml
docker compose down && docker compose up -d
```

### Token refresh

Runner registration tokens expire after 1 hour. When the container is rebuilt or the token expires, get a new one:

```bash
NEW_TOKEN=$(gh api --method POST /repos/<owner>/<repo>/actions/runners/registration-token --jq '.token')
sed -i "s/RUNNER_TOKEN:.*/RUNNER_TOKEN: $NEW_TOKEN/" docker-compose.yml
docker compose down && docker compose up -d
```

### Adding Android SDK (optional)

Uncomment the Android section in the `Dockerfile` and adjust SDK versions as needed.

## Template structure

```
template/
├── docker-compose.yml   # Service definition, env vars
├── Dockerfile           # Ubuntu + runner agent
└── entrypoint.sh        # Register + listen for jobs
```

## Files

### `template/docker-compose.yml`

```yaml
services:
  github-runner:
    build: .
    container_name: github-runner
    restart: unless-stopped
    environment:
      REPO_URL: https://github.com/<owner>/<repo>
      RUNNER_TOKEN: <token>
    volumes:
      - runner-cache:/home/runner/.gradle

volumes:
  runner-cache:
```

### `template/Dockerfile`

Includes:
- Ubuntu 24.04 base
- Runtime tools: curl, git, unzip, jq, sudo
- `runner` user with passwordless sudo (for KVM etc.)
- GitHub Actions runner agent v2.336.0
- Optional block (commented out) for Android SDK + JDK

### `template/entrypoint.sh`

- Registers runner with `REPO_URL` + `RUNNER_TOKEN`
- Sets labels `docker,android` (customize as needed)
- Cleans up registration on container stop
