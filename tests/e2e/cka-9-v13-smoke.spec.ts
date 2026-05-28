/**
 * CKA-9 — v1.3 baseline smoke against the published stack.
 *
 * Acceptance (per _WIP/SPEC.pgCK.ROADMAP.v0.2-devel.md §4):
 *   "one new Playwright test under tests/e2e/ locks 'page loads,
 *    CKClient subscribes, broadcast renders' against the v0.6+ image"
 *
 * Three coupled checks land here:
 *   1. Page loads over TLS and the display surface is present.
 *   2. /cklib/ mount serves CK.Lib.Js v1.3.0 (per the bundle's `components.cklib.version`).
 *   3. CKClient — after construction in display-app.js — reaches the
 *      "Subscribed to event.pgCK.Display" state, proving the v1.3-shaped
 *      subscription handshake completed against the running NATS WSS.
 *
 * The optional fourth check (live NATS publish → page re-render) is guarded
 * behind PGCK_E2E_LIVE_NATS=1 because CI runners don't ship the `nats` CLI;
 * locally on the workstation it runs the round-trip.
 */

import { test, expect } from '@playwright/test';
import { execSync } from 'node:child_process';

const BASE_URL = 'https://pgck.localhost';
const EXPECTED_CKLIB_VERSION_RE = /^1\.3\./;  // accept any v1.3.x patch
const DISPLAY_SUBJECT = 'event.pgCK.Display';
const NATS_PUBLISH_CMD =
  'nats --server=nats://dev:devpass-change-me@127.0.0.1:14222 pub';

test.describe('CKA-9 — v1.3 baseline smoke', () => {
  test('display page loads over HTTPS', async ({ page }) => {
    const response = await page.goto(`${BASE_URL}/`);
    expect(response?.status()).toBeLessThan(400);
    await expect(page).toHaveTitle('pgCK Display — NATS Messages');
  });

  test('/cklib/ mount serves CK.Lib.Js v1.3.0', async ({ page }) => {
    // Fetch from inside the page so the browser's hosts-file resolution
    // for pgck.localhost is used; Playwright's request fixture uses Node's
    // resolver and would fail with ENOTFOUND on the local-only hostname.
    await page.goto(`${BASE_URL}/`);
    const pkg = await page.evaluate(async () => {
      const r = await fetch('/cklib/package.json');
      return { status: r.status, body: await r.json() };
    });
    expect(pkg.status).toBe(200);
    expect(pkg.body.name).toBe('@conceptkernel/cklib');
    expect(pkg.body.version).toMatch(EXPECTED_CKLIB_VERSION_RE);
  });

  test('CKClient reaches Subscribed state on event.pgCK.Display', async ({ page }) => {
    await page.goto(`${BASE_URL}/`);

    const status = page.locator('#connection-status');
    await expect(status).toHaveText(
      new RegExp(`Subscribed to ${DISPLAY_SUBJECT.replace(/\./g, '\\.')}`),
      { timeout: 10_000 },
    );

    const subjectCell = page.locator('#nats-subject');
    await expect(subjectCell).toHaveText(DISPLAY_SUBJECT);
  });

  test('NATS broadcast renders into #last-payload', async ({ page }) => {
    test.skip(
      !process.env.PGCK_E2E_LIVE_NATS,
      'requires live NATS + `nats` CLI; set PGCK_E2E_LIVE_NATS=1 to run',
    );

    await page.goto(`${BASE_URL}/`);
    await expect(page.locator('#connection-status')).toHaveText(
      new RegExp(`Subscribed to ${DISPLAY_SUBJECT.replace(/\./g, '\\.')}`),
      { timeout: 10_000 },
    );

    const probe = `cka-9-${Date.now()}`;
    const payload = JSON.stringify({ kind: 'message', message: probe });
    execSync(`${NATS_PUBLISH_CMD} ${DISPLAY_SUBJECT} '${payload}'`, {
      stdio: 'pipe',
    });

    await expect(page.locator('#last-payload')).toContainText(probe, {
      timeout: 5_000,
    });
  });
});
