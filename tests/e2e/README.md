# pgCK Playwright E2E Tests (L7 HTTPS)

End-to-end tests for pgCK web services running over HTTPS via Envoy Gateway at `pgck.localhost`.

## Prerequisites

### 1. Envoy Gateway Setup

The tests require Envoy TLS termination at `pgck.localhost:443`:

```bash
# From $ENVOY_TLS_DIR/
./start.sh
# Envoy listens on 443, routes to:
#   - pgck-web on 8001 (/api/*, /static/*, /)
#   - pgck-nats-wss on 9222 (/wss/*)
#   - pgck-processor on 8002 (/processor/*, optional)
```

### 2. Certificates

Self-signed certificates (mkcert) already generated and deployed:

```bash
# Location: $ENVOY_TLS_DIR/certs/
ls -la pgck.localhost.pem pgck.localhost-key.pem
```

### 3. DNS Resolution

Ensure `/etc/hosts` has:

```
127.0.0.1 pgck.localhost
127.0.0.1 *.pgck.localhost
```

Or trust via mkcert:

```bash
mkcert -install
```

## Installation

```bash
# Install Node.js dependencies
npm install -D @playwright/test @types/node typescript

# Or with yarn/pnpm
yarn add -D @playwright/test @types/node typescript
pnpm add -D @playwright/test @types/node typescript
```

## Running Tests

### All Tests

```bash
npx playwright test
```

### Specific Test File

```bash
npx playwright test display-page.spec.ts
npx playwright test board-page.spec.ts
npx playwright test api-integration.spec.ts
```

### Single Test

```bash
npx playwright test -g "should load display page"
```

### Browser-Specific

```bash
npx playwright test --project=chromium
npx playwright test --project=firefox
npx playwright test --project=webkit
```

### Debug Mode

```bash
npx playwright test --debug
```

### Headed Mode (See Browser)

```bash
npx playwright test --headed
```

### Generate HTML Report

```bash
npx playwright test
npx playwright show-report
```

## Configuration

### File: `playwright.config.ts`

- **Base URL**: `https://pgck.localhost` (Envoy TLS endpoint)
- **Self-signed certs**: `ignoreHTTPSErrors: true`
- **Web server**: Auto-starts pgck-web on 8001
- **Trace**: `on-first-retry` (captured on failures)
- **Screenshot**: `only-on-failure`

### Custom Environment Variables

```bash
# Override base URL
BASE_URL=https://pgck.example.com npx playwright test

# Skip web server startup (if running manually)
SKIP_WEB_SERVER=1 npx playwright test

# Debug mode
DEBUG=pw:api npx playwright test
```

### Screenshots (convention — keep them out of the repo root)

All screenshots live under **`tests/e2e/screenshots/`** (gitignored — binary artifacts are
never committed to the public `styk-tv/pgCK` remote). This is the home for:

- Test-runner failure screenshots / traces (the config writes runner artifacts under
  `test-results/`, also gitignored).
- Ad-hoc `page.screenshot({ path: 'screenshots/<name>.png' })` calls — the relative path
  resolves against this directory (Playwright runs with cwd `tests/e2e`).
- **Playwright MCP** captures during manual verification: pass the filename as
  `tests/e2e/screenshots/<name>.png` (the MCP server's *default* output dir is a global
  Claude setting, so it does not honor this dir automatically — name the path explicitly, or
  set the playwright-mcp `--output-dir` to this folder).

Do **not** write screenshots to the repo root. They were relocated here on 2026-06-10.

## Test Structure

### Display Page (`display-page.spec.ts`)

- ✓ Load HTTPS page
- ✓ Nav menu visible
- ✓ NATS connection status
- ✓ Protocol documentation
- ✓ Audio controls
- ✓ Navigate to board
- ✓ TLS certificate handling

### Board Page (`board-page.spec.ts`)

- ✓ Load HTTPS page
- ✓ Nav menu visible
- ✓ Task creation form
- ✓ Kernel columns
- ✓ Goal/kernel selectors (API-populated)
- ✓ Navigate to display
- ✓ API data fetching

### API Integration (`api-integration.spec.ts`)

- ✓ Board snapshot API (L7 HTTPS)
- ✓ Goals API
- ✓ Kernels API
- ✓ Envoy L7 routing verification
- ✓ HTTPS enforcement
- ✓ TLS session reuse
- ✓ Prefix routing validation
- ✓ Browser config protocol version

## L7 Testing Over TLS

These tests verify **application-layer (L7) behavior over HTTPS**:

1. **TLS Handshake**: Self-signed certificates accepted (ignored via `ignoreHTTPSErrors`)
2. **HTTP/2**: Envoy terminates TLS, proxies HTTP/1.1 to backends
3. **Prefix Routing**: Envoy rewrites `/api/*` to `/` on upstream (8001)
4. **CORS/Security Headers**: Verified across HTTPS boundaries
5. **Session Persistence**: TLS session reuse across multiple requests

## Debugging

### 1. Check Envoy is Running

```bash
curl -k https://pgck.localhost/
# Should return HTML (no TLS errors with -k flag)
```

### 2. Check Web Service

```bash
curl http://127.0.0.1:8001/
# Should return HTML (HTTP, not HTTPS)
```

### 3. Check Envoy Logs

```bash
tail -f $ENVOY_TLS_DIR/logs/envoy.log
```

### 4. Check Upstream Health

```bash
curl -k https://pgck.localhost/
# Watch Envoy logs for upstream 127.0.0.1:8001 activity
```

### 5. Playwright Debug Output

```bash
DEBUG=pw:api npx playwright test -g "should load" --headed
```

## Troubleshooting

### **Certificate errors**

```
Error: Error: write ECONNRESET
```

Solution: Ensure certificates are deployed to `$ENVOY_TLS_DIR/certs/`

### **Web server fails to start**

```
Error: Command failed: sh -c "cd ../..; source .venv/bin/activate..."
```

Solution: Check Python venv and pgck-web dependencies:

```bash
source .venv/bin/activate
pip install -r web/requirements.txt psycopg2-binary nats-py
```

### **502 Bad Gateway**

```
Error: 502 Bad Gateway from Envoy
```

Solution: Verify web service is running on 8001:

```bash
curl http://127.0.0.1:8001/
```

### **Connection refused on pgck.localhost**

```
Error: ECONNREFUSED: connect ECONNREFUSED 127.0.0.1:443
```

Solution: Ensure Envoy is running:

```bash
ps aux | grep envoy
# Restart if needed:
cd $ENVOY_TLS_DIR && ./start.sh
```

## CI/CD Integration

In GitHub Actions or similar:

```yaml
- name: Run Playwright Tests
  run: |
    npm install
    npx playwright install --with-deps
    npx playwright test
  env:
    NODE_TLS_REJECT_UNAUTHORIZED: 0  # For CI environment
```

## References

- **Envoy Config**: `$ENVOY_TLS_DIR/envoy.yaml` (environment-specific local TLS proxy)
- **Web Service**: `web/app.py` (FastAPI on port 8001)
- **Playwright Docs**: https://playwright.dev

---

**Status**: ACTIVE — Tests validate L7 HTTPS routing via Envoy at pgck.localhost  
**Last Updated**: 2026-05-27
