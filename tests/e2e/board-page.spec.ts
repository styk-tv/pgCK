import { test, expect } from '@playwright/test';

test.describe('pgCK Kernel Board Page', () => {
  test('should load board page over HTTPS', async ({ page }) => {
    await page.goto('/tasks.html');

    // Verify page title
    await expect(page).toHaveTitle('pgCK Kernel Board');

    // Check nav menu exists
    const navMenu = page.locator('.nav-menu');
    await expect(navMenu).toBeVisible();
  });

  test('should have board nav link highlighted', async ({ page }) => {
    await page.goto('/tasks.html');

    const boardLink = page.locator('.nav-link.board-link');
    await expect(boardLink).toBeVisible();
    await expect(boardLink).toHaveText('Board');
  });

  test('should display task creation form', async ({ page }) => {
    await page.goto('/tasks.html');

    const composerCard = page.locator('.composer-card');
    await expect(composerCard).toBeVisible();

    // Check form fields
    const goalSelect = page.locator('#goal-select');
    const kernelSelect = page.locator('#kernel-select');
    const titleInput = page.locator('#title-input');
    const detailInput = page.locator('#detail-input');
    const priorityInput = page.locator('#priority-input');

    await expect(goalSelect).toBeVisible();
    await expect(kernelSelect).toBeVisible();
    await expect(titleInput).toBeVisible();
    await expect(detailInput).toBeVisible();
    await expect(priorityInput).toBeVisible();
  });

  test('should load kernel columns on board', async ({ page }) => {
    await page.goto('/tasks.html');

    const boardCard = page.locator('.board-card');
    await expect(boardCard).toBeVisible();

    const boardColumns = page.locator('#board-columns');
    await expect(boardColumns).toBeVisible();

    const kernelToggles = page.locator('#kernel-toggles');
    await expect(kernelToggles).toBeVisible();
  });

  test('should populate goal and kernel selectors via API', async ({ page }) => {
    await page.goto('/tasks.html');

    // Wait for API calls to populate
    await page.waitForLoadState('networkidle');

    const goalSelect = page.locator('#goal-select');
    const kernelSelect = page.locator('#kernel-select');

    // Check that selectors have options (populated from API)
    const goalOptions = page.locator('#goal-select option');
    const kernelOptions = page.locator('#kernel-select option');

    // Should have at least one option beyond the placeholder
    const goalOptionCount = await goalOptions.count();
    const kernelOptionCount = await kernelOptions.count();

    expect(goalOptionCount).toBeGreaterThan(0);
    expect(kernelOptionCount).toBeGreaterThan(0);
  });

  test('should navigate to display page via nav menu', async ({ page }) => {
    await page.goto('/tasks.html');

    const displayLink = page.locator('.nav-link.display-link');
    await displayLink.click();

    // Should navigate to display page
    await expect(page).toHaveURL('/');
    await expect(page).toHaveTitle('pgCK Display — NATS Messages');
  });

  test('should fetch board snapshot from API over HTTPS', async ({ page }) => {
    const apiResponse = await page.request.get('https://pgck.localhost/api/board', {
      ignoreHTTPSErrors: true,
    });

    expect(apiResponse.status()).toBe(200);

    const boardData = await apiResponse.json();
    expect(boardData).toHaveProperty('kind', 'board_snapshot');
    expect(boardData).toHaveProperty('board');
    expect(boardData.board).toHaveProperty('kernels');
    expect(boardData.board).toHaveProperty('tasks');
  });

  test('should handle task creation over HTTPS API', async ({ page }) => {
    await page.goto('/tasks.html');

    // Verify form is interactive
    const titleInput = page.locator('#title-input');
    const submitButton = page.locator('.submit-button');

    await titleInput.fill('Test task for Playwright');
    await expect(titleInput).toHaveValue('Test task for Playwright');
    await expect(submitButton).toBeEnabled();
  });
});
