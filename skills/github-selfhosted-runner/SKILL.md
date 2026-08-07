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

### Pre-flight token check (avoid 404 / "already configured")

Runner registration tokens expire after **1 hour**. The classic failure mode:

1. Docker is stopped/reboots while the container runs with `restart: unless-stopped`.
2. Docker Desktop comes back → the container auto-restarts with the **old, expired token**.
3. `entrypoint.sh` hits a stale `.runner` → `Cannot configure the runner because it is already configured` + `404 Not Found` from `POST https://api.github.com/actions/runner-registration` (token no longer matches GitHub's records).

Prevent it by refreshing the token when the compose file is stale and confirming the runner state before (re)starting:

```bash
cd "$GITHUB_RUNNERS_PATH/<repo-name>"

# 1. Is a runner already registered for this repo? (check name/status)
gh api repos/<owner>/<repo>/actions/runners --jq '.runners[] | {name, status}'

# 2. Refresh token if docker-compose.yml is older than 1 hour
if test -n "$(find docker-compose.yml -mmin +60)"; then
  NEW_TOKEN=$(gh api --method POST /repos/<owner>/<repo>/actions/runners/registration-token --jq '.token')
  sed -i "s/RUNNER_TOKEN:.*/RUNNER_TOKEN: $NEW_TOKEN/" docker-compose.yml
fi

# 3. If a stale/offline runner is registered on GitHub, delete it first:
#    RUNNER_ID=$(gh api repos/<owner>/<repo>/actions/runners --jq '.runners[] | select(.status=="offline") | .id')
#    gh api --method DELETE repos/<owner>/<repo>/actions/runners/$RUNNER_ID

# 4. Start fresh
docker compose down && docker compose up -d
```

The template `entrypoint.sh` also deletes stale `.runner`/`.credentials` files before configuring, so a restarted container always re-registers cleanly (`--replace`) instead of failing with the 404.

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
- Deletes stale `.runner`/`.credentials` before configuring (prevents "already configured" + 404 on restart)
- Sets labels `docker,android` (customize as needed)
- Cleans up registration on container stop
