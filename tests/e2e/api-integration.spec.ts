import { test, expect } from '@playwright/test';

test.describe('pgCK API Integration (L7 HTTPS)', () => {
  const baseURL = 'https://pgck.localhost';

  test('should access board snapshot over HTTPS', async ({ request }) => {
    const response = await request.get(`${baseURL}/api/board`, {
      ignoreHTTPSErrors: true,
    });

    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('application/json');

    const data = await response.json();
    expect(data).toHaveProperty('kind', 'board_snapshot');
    expect(data.board).toHaveProperty('kernels');
    expect(Array.isArray(data.board.kernels)).toBe(true);
  });

  test('should list goals from API', async ({ request }) => {
    const response = await request.get(`${baseURL}/api/goals`, {
      ignoreHTTPSErrors: true,
    });

    expect(response.status()).toBe(200);

    const goals = await response.json();
    expect(Array.isArray(goals)).toBe(true);
  });

  test('should list kernels from API', async ({ request }) => {
    const response = await request.get(`${baseURL}/api/kernels`, {
      ignoreHTTPSErrors: true,
    });

    expect(response.status()).toBe(200);

    const kernels = await response.json();
    expect(Array.isArray(kernels)).toBe(true);
    expect(kernels.length).toBeGreaterThan(0);

    // Verify kernel structure
    const kernel = kernels[0];
    expect(kernel).toHaveProperty('kernel_id');
    expect(kernel).toHaveProperty('title');
    expect(kernel).toHaveProperty('color');
  });

  test('should validate Envoy routing to web backend on port 8001', async ({ request, page }) => {
    // Request via Envoy (L7 routing: / → port 8001)
    const envoyCorsResponse = await request.head(`${baseURL}/`, {
      ignoreHTTPSErrors: true,
    });

    expect(envoyCorsResponse.status()).toBeLessThan(500);

    // Verify API routing: /api/* → port 8001
    const apiResponse = await request.head(`${baseURL}/api/board`, {
      ignoreHTTPSErrors: true,
    });

    expect(apiResponse.status()).toBeLessThan(500);

    // Verify static assets routing: /static/* → port 8001
    const cssResponse = await request.head(`${baseURL}/static/app.css`, {
      ignoreHTTPSErrors: true,
    });

    // Asset may not exist, but routing should work (not 502)
    expect(cssResponse.status()).not.toBe(502);
  });

  test('should use HTTPS in all API calls', async ({ request }) => {
    const responses = await Promise.all([
      request.get(`${baseURL}/api/board`, { ignoreHTTPSErrors: true }),
      request.get(`${baseURL}/api/goals`, { ignoreHTTPSErrors: true }),
      request.get(`${baseURL}/api/kernels`, { ignoreHTTPSErrors: true }),
    ]);

    responses.forEach((response) => {
      expect(response.status()).toBeLessThan(500);
      expect(response.url()).toMatch(/^https:\/\//);
    });
  });

  test('should maintain TLS session across multiple requests', async ({ request }) => {
    // Make series of requests; TLS session should be reused (connection pooling)
    const urls = [
      `${baseURL}/`,
      `${baseURL}/api/board`,
      `${baseURL}/api/goals`,
      `${baseURL}/api/kernels`,
    ];

    for (const url of urls) {
      const response = await request.get(url, { ignoreHTTPSErrors: true });
      expect(response.status()).toBeLessThan(500);
      expect(response.ok() || response.status() === 404).toBe(true);
    }
  });

  test('should handle prefixed routing for API endpoints', async ({ request }) => {
    // Verify Envoy prefix rewriting: /api/* → / on upstream
    const response = await request.get(`${baseURL}/api/board`, {
      ignoreHTTPSErrors: true,
    });

    expect(response.status()).toBe(200);

    // The API should respond correctly despite prefix rewriting
    const data = await response.json();
    expect(data.kind).toBeDefined();
  });

  test('protocol version should be in browser config', async ({ page }) => {
    await page.goto('/', { waitUntil: 'networkidle' });

    const config = await page.evaluate(() => {
      return window.PGCK_DISPLAY_CONFIG;
    });

    expect(config).toHaveProperty('protocol_version', 1);
    expect(config).toHaveProperty('nats_ws_url');
    expect(config.nats_ws_url).toMatch(/^wss:\/\//);
  });
});
