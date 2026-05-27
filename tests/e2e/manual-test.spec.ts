import { test, expect } from '@playwright/test';

test.describe('Manual URL Test', () => {
  test('should load pgck.localhost directly', async ({ page }) => {
    console.log('About to navigate to https://pgck.localhost/');
    const response = await page.goto('https://pgck.localhost/', { waitUntil: 'domcontentloaded' });
    console.log('Response:', response?.status());
    expect(response?.status()).toBeLessThan(400);
  });
});
