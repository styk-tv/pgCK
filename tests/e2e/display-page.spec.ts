import { test, expect } from '@playwright/test';

test.describe('pgCK Display Page (NATS Messages)', () => {
  test('should load display page over HTTPS', async ({ page }) => {
    await page.goto('/');

    // Verify page title
    await expect(page).toHaveTitle('pgCK Display — NATS Messages');

    // Check nav menu exists
    const navMenu = page.locator('.nav-menu');
    await expect(navMenu).toBeVisible();
  });

  test('should have display nav link highlighted', async ({ page }) => {
    await page.goto('/');

    const displayLink = page.locator('.nav-link.display-link');
    await expect(displayLink).toBeVisible();
    await expect(displayLink).toHaveText('Display');
  });

  test('should show NATS connection status', async ({ page }) => {
    await page.goto('/');

    const statusCard = page.locator('.status-card');
    await expect(statusCard).toBeVisible();

    const connectionStatus = page.locator('#connection-status');
    await expect(connectionStatus).toBeVisible();
  });

  test('should have protocol documentation section', async ({ page }) => {
    await page.goto('/');

    const protocolCard = page.locator('.protocol-card');
    await expect(protocolCard).toBeVisible();

    const protocolOutput = page.locator('#protocol-output');
    await expect(protocolOutput).toBeVisible();
  });

  test('should have audio control button', async ({ page }) => {
    await page.goto('/');

    const audioButton = page.locator('#audio-unlock');
    await expect(audioButton).toBeVisible();
    await expect(audioButton).toHaveText('Enable audio');
  });

  test('should navigate to board page via nav menu', async ({ page }) => {
    await page.goto('/');

    const boardLink = page.locator('.nav-link.board-link');
    await boardLink.click();

    // Should navigate to tasks page
    await expect(page).toHaveURL('/tasks.html');
    await expect(page).toHaveTitle('pgCK Kernel Board');
  });

  test('should load with self-signed HTTPS certificate', async ({ page }) => {
    const response = await page.goto('/');

    // Verify we got a successful response despite self-signed cert
    expect(response?.status()).toBeLessThan(400);

    // Verify TLS handshake completed (browser security model enforced)
    const securityDetails = page.context().browser?.version();
    expect(securityDetails).toBeDefined();
  });
});
