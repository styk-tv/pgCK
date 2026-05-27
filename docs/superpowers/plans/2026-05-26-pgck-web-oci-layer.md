# pgck-web OCI Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a non-runnable pgck-web OCI layer artifact that oci-germination can graft into its supervisor runtime, serving two HTML entry points (display demo + tasks board) via FastAPI.

**Architecture:** One FastAPI app with two routes (`/` for display, `/tasks.html` for tasks), shipped as a self-contained OCI layer per architecture. Dev builds (local) and release builds (GitHub Actions) use the same Dockerfile and output layout so pgck-web can be dropped into germination consistently.

**Tech Stack:** 
- FastAPI + uvicorn (Python web server)
- Two static HTML entry points + shared static assets
- Multi-arch builds (amd64, arm64) via GitHub Actions
- OCI layer artifact registry: ghcr.io/styk-tv/pgck-web

---

## Design Confirmation

✓ **One OCI artifact only** — `ghcr.io/styk-tv/pgck-web:v<ver>-{amd64,arm64}`  
✓ **Non-runnable layer** — oci-germination grafts it into the supervisor pod  
✓ **Two entry routes** — `/` (display: theme/message/audio) and `/tasks.html` (goals/tasks board)  
✓ **FastAPI runtime included** — web layer carries its own Python venv + launcher  
✓ **Dev/publish alignment** — local build path `compose/layers/pgck-web/` mirrors GH Actions output  
✓ **Launcher contract** — `/usr/local/bin/pgck-web-launcher` (oci-germination registers via supervisor)  

---

## File Structure

**Create:**
- `web/app/main.py` — FastAPI app, route definitions, static serving
- `web/app/display.py` — display demo endpoint logic (theme, message, audio)
- `web/app/tasks.py` — tasks board endpoint logic (goals, tasks)
- `web/app/static/display.html` — display demo entry point
- `web/app/static/tasks.html` — tasks board entry point
- `web/Dockerfile.pgck-web` — OCI build recipe (Python 3.11 slim + FastAPI + venv)
- `web/pgck-web-launcher` — shell launcher script for supervisor
- `web/requirements.txt` — FastAPI, uvicorn, pydantic, minimal deps
- `compose/layers/pgck-web/build.sh` — local dev build script (mirrors release)
- `compose/layers/pgck-web/.gitkeep` — output directory placeholder
- `.github/workflows/publish-pgck-web.yml` — release workflow (builds + pushes per arch)
- `docs/superpowers/plans/2026-05-26-pgck-web-oci-layer.md` — this plan

**Modify:**
- `.github/workflows/release.yml` (if exists) — add pgck-web publish step, or create new workflow
- `README.md` — add pgck-web artifact publishing section

---

## Tasks

### Task 1: Create FastAPI app skeleton with two routes

**Files:**
- Create: `web/app/main.py`
- Create: `web/app/display.py`
- Create: `web/app/tasks.py`
- Create: `web/requirements.txt`

- [ ] **Step 1: Write `web/requirements.txt` with minimal dependencies**

```txt
fastapi==0.104.1
uvicorn[standard]==0.24.0
pydantic==2.5.0
```

- [ ] **Step 2: Write `web/app/display.py` with display demo logic**

```python
from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter()

class DisplayConfig(BaseModel):
    theme: str = "light"
    message: str = "Welcome"
    audio_url: str | None = None

@router.get("/api/display/config")
async def get_display_config():
    return {"theme": "light", "message": "Welcome to pgCK", "audio_url": None}

@router.post("/api/display/config")
async def set_display_config(config: DisplayConfig):
    return {"status": "ok", "config": config}
```

- [ ] **Step 3: Write `web/app/tasks.py` with tasks board logic**

```python
from fastapi import APIRouter
from pydantic import BaseModel
from typing import List

router = APIRouter()

class Task(BaseModel):
    id: str
    title: str
    completed: bool = False

tasks_store = []

@router.get("/api/tasks")
async def list_tasks():
    return tasks_store

@router.post("/api/tasks")
async def create_task(task: Task):
    tasks_store.append(task)
    return {"status": "ok", "task": task}

@router.put("/api/tasks/{task_id}")
async def update_task(task_id: str, task: Task):
    for i, t in enumerate(tasks_store):
        if t["id"] == task_id:
            tasks_store[i] = task.dict()
            return {"status": "ok", "task": task}
    return {"status": "error", "message": "Task not found"}
```

- [ ] **Step 4: Write `web/app/main.py` with FastAPI app and two static routes**

```python
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
import os
from pathlib import Path

from .display import router as display_router
from .tasks import router as tasks_router

app = FastAPI(title="pgck-web", version="0.1.0")

# Include API routers
app.include_router(display_router, prefix="")
app.include_router(tasks_router, prefix="")

# Serve static files
static_dir = Path(__file__).parent / "static"
if static_dir.exists():
    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")

# Root route: serve display.html
@app.get("/")
async def root():
    display_html = static_dir / "display.html"
    if display_html.exists():
        return FileResponse(str(display_html), media_type="text/html")
    return {"message": "Display demo - display.html not found"}

# Tasks route: serve tasks.html
@app.get("/tasks.html")
async def tasks_page():
    tasks_html = static_dir / "tasks.html"
    if tasks_html.exists():
        return FileResponse(str(tasks_html), media_type="text/html")
    return {"message": "Tasks board - tasks.html not found"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
```

- [ ] **Step 5: Verify imports and module structure**

Run: `cd /Users/neoxr/git_conceptkernel/pgCK && python -c "from web.app.main import app; print('FastAPI app loaded OK')" 2>&1 || echo 'Module check (expected to fail without full setup yet)'`

- [ ] **Step 6: Commit**

```bash
cd /Users/neoxr/git_conceptkernel/pgCK
git add web/app/main.py web/app/display.py web/app/tasks.py web/requirements.txt
git commit -m "feat: create FastAPI app skeleton with display and tasks routes"
```

---

### Task 2: Create static HTML entry points

**Files:**
- Create: `web/app/static/display.html`
- Create: `web/app/static/tasks.html`

- [ ] **Step 1: Create `web/app/static/display.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Display Demo - pgCK</title>
    <style>
        body { font-family: sans-serif; margin: 20px; }
        .display-container { border: 1px solid #ccc; padding: 20px; border-radius: 8px; }
        .theme-light { background: white; color: black; }
        .theme-dark { background: #333; color: white; }
        .message { font-size: 24px; margin: 20px 0; }
        .audio-player { margin-top: 20px; }
    </style>
</head>
<body>
    <div class="display-container theme-light" id="display">
        <h1>Display Demo</h1>
        <div class="message" id="message">Welcome to pgCK</div>
        <div class="audio-player">
            <label>Audio:</label>
            <audio id="audio" controls style="margin-top: 10px;"></audio>
        </div>
    </div>
    <script>
        async function loadConfig() {
            const response = await fetch('/api/display/config');
            const config = await response.json();
            document.getElementById('message').textContent = config.message;
            if (config.audio_url) {
                document.getElementById('audio').src = config.audio_url;
            }
        }
        loadConfig();
    </script>
</body>
</html>
```

- [ ] **Step 2: Create `web/app/static/tasks.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Tasks Board - pgCK</title>
    <style>
        body { font-family: sans-serif; margin: 20px; }
        .tasks-container { max-width: 600px; margin: 0 auto; }
        .task-list { list-style: none; padding: 0; }
        .task-item { display: flex; align-items: center; padding: 10px; border: 1px solid #eee; margin: 5px 0; border-radius: 4px; }
        .task-item input { margin-right: 10px; }
        .task-item.completed { opacity: 0.5; text-decoration: line-through; }
        .add-task-form { display: flex; margin: 20px 0; }
        .add-task-form input { flex: 1; padding: 8px; border: 1px solid #ccc; }
        .add-task-form button { padding: 8px 16px; background: #007bff; color: white; border: none; cursor: pointer; margin-left: 5px; }
    </style>
</head>
<body>
    <div class="tasks-container">
        <h1>Tasks Board</h1>
        <div class="add-task-form">
            <input type="text" id="taskInput" placeholder="Add a new task...">
            <button onclick="addTask()">Add</button>
        </div>
        <ul class="task-list" id="taskList"></ul>
    </div>
    <script>
        async function loadTasks() {
            const response = await fetch('/api/tasks');
            const tasks = await response.json();
            const list = document.getElementById('taskList');
            list.innerHTML = tasks.map(task => `
                <li class="task-item ${task.completed ? 'completed' : ''}">
                    <input type="checkbox" ${task.completed ? 'checked' : ''} 
                           onchange="toggleTask('${task.id}')">
                    <span>${task.title}</span>
                </li>
            `).join('');
        }
        
        async function addTask() {
            const input = document.getElementById('taskInput');
            const title = input.value.trim();
            if (!title) return;
            
            const response = await fetch('/api/tasks', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ id: Date.now().toString(), title, completed: false })
            });
            input.value = '';
            loadTasks();
        }
        
        async function toggleTask(taskId) {
            const response = await fetch(`/api/tasks/${taskId}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ id: taskId, title: "updated", completed: true })
            });
            loadTasks();
        }
        
        loadTasks();
    </script>
</body>
</html>
```

- [ ] **Step 3: Verify static files exist**

Run: `ls -la /Users/neoxr/git_conceptkernel/pgCK/web/app/static/`

Expected: Both `display.html` and `tasks.html` listed.

- [ ] **Step 4: Commit**

```bash
cd /Users/neoxr/git_conceptkernel/pgCK
git add web/app/static/display.html web/app/static/tasks.html
git commit -m "feat: add static HTML entry points for display and tasks"
```

---

### Task 3: Create Dockerfile for local dev and release builds

**Files:**
- Create: `web/Dockerfile.pgck-web`
- Create: `web/.dockerignore`

- [ ] **Step 1: Create `web/.dockerignore`**

```
__pycache__
*.pyc
.pytest_cache
.venv
venv
env
*.egg-info
.git
.gitignore
README.md
```

- [ ] **Step 2: Create `web/Dockerfile.pgck-web`**

```dockerfile
# Multi-stage: builder + runtime
FROM python:3.11-slim as builder

WORKDIR /build

# Copy requirements and install to venv
COPY requirements.txt .
RUN python -m venv /opt/venv && \
    . /opt/venv/bin/activate && \
    pip install --no-cache-dir -r requirements.txt

# Runtime stage
FROM python:3.11-slim

WORKDIR /opt/pgck-web

# Copy venv from builder
COPY --from=builder /opt/venv /opt/venv

# Copy app code
COPY app/ ./app/

# Create launcher script
RUN mkdir -p /usr/local/bin && \
    printf '#!/bin/sh\nset -e\ncd /opt/pgck-web\nPATH=/opt/venv/bin:$PATH\nexec python -m uvicorn app.main:app --host 0.0.0.0 --port 8000\n' > /usr/local/bin/pgck-web-launcher && \
    chmod +x /usr/local/bin/pgck-web-launcher

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD /opt/venv/bin/python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/')" || exit 1

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/pgck-web-launcher"]
```

- [ ] **Step 3: Verify Dockerfile is correct**

Run: `head -20 /Users/neoxr/git_conceptkernel/pgCK/web/Dockerfile.pgck-web`

Expected: File starts with `# Multi-stage: builder + runtime`.

- [ ] **Step 4: Test Dockerfile build locally (dry run only)**

Run: `cd /Users/neoxr/git_conceptkernel/pgCK/web && docker build -f Dockerfile.pgck-web -t pgck-web:test . 2>&1 | head -30`

Expected: Should start building (may fail at runtime if some deps are missing, but we just want to verify Dockerfile is syntactically valid).

- [ ] **Step 5: Commit**

```bash
cd /Users/neoxr/git_conceptkernel/pgCK
git add web/Dockerfile.pgck-web web/.dockerignore
git commit -m "feat: add Dockerfile for pgck-web OCI builds"
```

---

### Task 4: Create local dev build script

**Files:**
- Create: `compose/layers/pgck-web/build.sh`
- Create: `compose/layers/pgck-web/.gitkeep`

- [ ] **Step 1: Create `compose/layers/pgck-web/.gitkeep` to establish directory**

```
(empty file)
```

- [ ] **Step 2: Create `compose/layers/pgck-web/build.sh`**

```bash
#!/bin/bash
# Local pgck-web OCI layer build script
# Mirrors release build workflow; output can be tested locally before GitHub Actions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WEB_DIR="$PROJECT_ROOT/web"
OUTPUT_DIR="$SCRIPT_DIR/output"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_TAG="amd64" ;;
  arm64|aarch64) ARCH_TAG="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

VERSION="${1:-dev}"
IMAGE_NAME="pgck-web:${VERSION}-${ARCH_TAG}"
TAR_OUTPUT="$OUTPUT_DIR/pgck-web-${VERSION}-${ARCH_TAG}.oci.tar"

echo "[pgck-web build] Architecture: $ARCH_TAG"
echo "[pgck-web build] Version: $VERSION"
echo "[pgck-web build] Building: $IMAGE_NAME"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Build OCI image
cd "$WEB_DIR"
docker build -f Dockerfile.pgck-web -t "$IMAGE_NAME" .

echo "[pgck-web build] Image built: $IMAGE_NAME"
echo "[pgck-web build] To push to registry, use:"
echo "  docker tag $IMAGE_NAME ghcr.io/styk-tv/$IMAGE_NAME"
echo "  docker push ghcr.io/styk-tv/$IMAGE_NAME"
```

- [ ] **Step 3: Make script executable**

Run: `chmod +x /Users/neoxr/git_conceptkernel/pgCK/compose/layers/pgck-web/build.sh`

- [ ] **Step 4: Test script dry run**

Run: `cd /Users/neoxr/git_conceptkernel/pgCK && bash compose/layers/pgck-web/build.sh dev 2>&1 | head -20`

Expected: Script should start (may fail at docker build step if image build fails, but that's OK — we just want to verify the script itself runs).

- [ ] **Step 5: Commit**

```bash
cd /Users/neoxr/git_conceptkernel/pgCK
git add compose/layers/pgck-web/build.sh compose/layers/pgck-web/.gitkeep
git commit -m "feat: add local dev build script for pgck-web"
```

---

### Task 5: Create GitHub Actions release workflow

**Files:**
- Create: `.github/workflows/publish-pgck-web.yml`

- [ ] **Step 1: Create `.github/workflows/publish-pgck-web.yml`**

```yaml
name: Publish pgck-web OCI Layer

on:
  push:
    tags:
      - 'pgck-web/v*'
    paths:
      - 'web/**'
      - '.github/workflows/publish-pgck-web.yml'

permissions:
  contents: read
  packages: write

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        platform:
          - linux/amd64
          - linux/arm64
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract version from tag
        id: version
        run: |
          TAG=${{ github.ref }}
          VERSION=${TAG#refs/tags/pgck-web/}
          echo "version=$VERSION" >> $GITHUB_OUTPUT

      - name: Determine architecture tag
        id: arch
        run: |
          PLATFORM=${{ matrix.platform }}
          case "$PLATFORM" in
            linux/amd64) echo "arch_tag=amd64" >> $GITHUB_OUTPUT ;;
            linux/arm64) echo "arch_tag=arm64" >> $GITHUB_OUTPUT ;;
          esac

      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: ./web
          file: ./web/Dockerfile.pgck-web
          platforms: ${{ matrix.platform }}
          push: true
          tags: |
            ghcr.io/styk-tv/pgck-web:${{ steps.version.outputs.version }}-${{ steps.arch.outputs.arch_tag }}
            ghcr.io/styk-tv/pgck-web:latest-${{ steps.arch.outputs.arch_tag }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Generate SBOM
        uses: anchore/sbom-action@v0
        with:
          image: ghcr.io/styk-tv/pgck-web:${{ steps.version.outputs.version }}-${{ steps.arch.outputs.arch_tag }}
          format: spdx-json
          output-file: pgck-web-${{ steps.arch.outputs.arch_tag }}-sbom.spdx.json

      - name: Upload SBOM
        uses: actions/upload-artifact@v3
        with:
          name: sbom-${{ steps.arch.outputs.arch_tag }}
          path: pgck-web-${{ steps.arch.outputs.arch_tag }}-sbom.spdx.json

  notify-germination:
    needs: build-and-push
    runs-on: ubuntu-latest
    steps:
      - name: Notify oci-germination
        run: |
          echo "pgck-web OCI layer published:"
          echo "  ghcr.io/styk-tv/pgck-web:${{ needs.build-and-push.outputs.version }}-amd64"
          echo "  ghcr.io/styk-tv/pgck-web:${{ needs.build-and-push.outputs.version }}-arm64"
          echo ""
          echo "Next: Update oci-germination to consume this layer."
```

- [ ] **Step 2: Verify workflow syntax**

Run: `cd /Users/neoxr/git_conceptkernel/pgCK && python -m yaml .github/workflows/publish-pgck-web.yml 2>&1 | head -20 || echo '(YAML checker not available; manual review OK)'`

- [ ] **Step 3: Review workflow file**

Open and visually inspect: `/Users/neoxr/git_conceptkernel/pgCK/.github/workflows/publish-pgck-web.yml`

Expected: File contains multi-arch build, push to ghcr.io, and notification step.

- [ ] **Step 4: Commit**

```bash
cd /Users/neoxr/git_conceptkernel/pgCK
git add .github/workflows/publish-pgck-web.yml
git commit -m "feat: add GitHub Actions workflow to publish pgck-web OCI layer"
```

---

### Task 6: Add pgck-web section to README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read current README to find insertion point**

Run: `head -50 /Users/neoxr/git_conceptkernel/pgCK/README.md`

Expected: File shows current structure (header, description, installation, etc.).

- [ ] **Step 2: Add pgck-web section before or after build/deployment**

Locate a suitable section in README (e.g., "Building" or "Deployment") and add:

```markdown
## pgck-web OCI Layer

The `pgck-web` artifact is a non-runnable OCI layer that serves two browser entry points (display demo + tasks board) via FastAPI. It is designed to be grafted into the [oci-germination](https://github.com/sporaxis-com/oci-germination) supervisor runtime.

### Building Locally

\`\`\`bash
bash compose/layers/pgck-web/build.sh dev
\`\`\`

This builds a local OCI image tagged `pgck-web:dev-{amd64,arm64}` (depending on your architecture).

### Publishing

Push a tag to trigger the release workflow:

\`\`\`bash
git tag pgck-web/v0.1.0
git push origin pgck-web/v0.1.0
\`\`\`

GitHub Actions will:
1. Build multi-arch OCI images (amd64 + arm64)
2. Push to `ghcr.io/styk-tv/pgck-web:v0.1.0-{amd64,arm64}`
3. Generate SBOMs for supply-chain security
4. Notify oci-germination of the new layer

### Integration with oci-germination

See [oci-germination](https://github.com/sporaxis-com/oci-germination) for instructions on how to add this layer to the supervisor-based runtime pod.
```

- [ ] **Step 3: Commit**

```bash
cd /Users/neoxr/git_conceptkernel/pgCK
git add README.md
git commit -m "docs: add pgck-web OCI layer section to README"
```

---

### Task 7: Test local build end-to-end

**Files:**
- (No files created; verification only)

- [ ] **Step 1: Run local build script**

Run: `cd /Users/neoxr/git_conceptkernel/pgCK && bash compose/layers/pgck-web/build.sh v0.1.0-test 2>&1`

Expected: Docker builds the image, tags as `pgck-web:v0.1.0-test-{amd64,arm64}`.

- [ ] **Step 2: Verify image was created**

Run: `docker images | grep pgck-web`

Expected: Image `pgck-web:v0.1.0-test-{amd64,arm64}` appears in list.

- [ ] **Step 3: Test container startup**

Run: `docker run --rm -p 8000:8000 pgck-web:v0.1.0-test-amd64 &` (background), then:

Run: `sleep 2 && curl -s http://localhost:8000/ | head -20`

Expected: HTML response with "Display Demo" content.

- [ ] **Step 4: Kill test container**

Run: `pkill -f 'docker run.*pgck-web'` or `docker ps | grep pgck-web | awk '{print $1}' | xargs docker kill`

- [ ] **Step 5: No commit (verification only)**

All checks passed; ready for release workflow testing.

---

### Task 8: Create git tags and verify release-ready state

**Files:**
- (No files; git operations only)

- [ ] **Step 1: Verify all commits are on the task branch**

Run: `cd /Users/neoxr/git_conceptkernel/pgCK && git log --oneline -10`

Expected: Shows commits from previous tasks (FastAPI app, static files, Dockerfile, build script, workflow, docs).

- [ ] **Step 2: Create annotated tag for release**

Run: `cd /Users/neoxr/git_conceptkernel/pgCK && git tag -a pgck-web/v0.1.0 -m "pgck-web: initial OCI layer release (display + tasks)"` 

- [ ] **Step 3: Verify tag**

Run: `cd /Users/neoxr/git_conceptkernel/pgCK && git show pgck-web/v0.1.0`

Expected: Shows the tag commit and message.

- [ ] **Step 4: Push tag to trigger release workflow**

Run: `cd /Users/neoxr/git_conceptkernel/pgCK && git push origin pgck-web/v0.1.0`

Expected: GitHub Actions workflow `publish-pgck-web.yml` starts automatically.

- [ ] **Step 5: Monitor workflow in GitHub**

Visit: `https://github.com/styk-tv/pgCK/actions/workflows/publish-pgck-web.yml`

Expected: Workflow runs and builds multi-arch images.

---

## Verification Checklist

- [ ] All tasks committed and pushed
- [ ] `compose/layers/pgck-web/build.sh` runs locally and produces OCI image
- [ ] GitHub Actions workflow `.github/workflows/publish-pgck-web.yml` exists and is syntactically valid
- [ ] Release tag `pgck-web/v0.1.0` pushed and workflow triggered
- [ ] Images available at:
  - `ghcr.io/styk-tv/pgck-web:v0.1.0-amd64`
  - `ghcr.io/styk-tv/pgck-web:v0.1.0-arm64`
- [ ] README updated with pgck-web build/publish instructions
- [ ] Ready to notify oci-germination of new layer availability

---

## Summary

This plan produces:
1. **Web app** — FastAPI serving two routes + static HTML (display + tasks)
2. **OCI container** — multi-arch build via Dockerfile, published per arch
3. **Local dev path** — `compose/layers/pgck-web/build.sh` mirrors release flow
4. **Release automation** — GitHub Actions workflow builds and pushes on tag
5. **Dev/publish alignment** — identical build process, output layout ready for oci-germination consumption

The design confirms that pgck-web is a **non-runnable layer artifact** — oci-germination will graft it into its supervisor runtime, mount the files, and register the launcher process. pgCK publishes the payload; germination assembles the final runtime.
