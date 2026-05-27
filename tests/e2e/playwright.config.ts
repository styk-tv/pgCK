import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,

  reporter: [
    ['html'],
    ['json', { outputFile: 'test-results/results.json' }],
    ['junit', { outputFile: 'test-results/junit.xml' }],
  ],

  use: {
    baseURL: 'https://pgck.localhost',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',

    // Accept self-signed certificates
    ignoreHTTPSErrors: true,
  },

  webServer: {
    command: 'sh -c "cd ../..; source .venv/bin/activate; PGHOST=127.0.0.1 PGPORT=15432 PGUSER=postgres PGDATABASE=pgck python -m uvicorn web_demo.app:app --host 127.0.0.1 --port 8001"',
    url: 'http://127.0.0.1:8001/healthz',
    reuseExistingServer: !process.env.CI,
    timeout: 120000,
  },

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'firefox',
      use: { ...devices['Desktop Firefox'] },
    },
    {
      name: 'webkit',
      use: { ...devices['Desktop Safari'] },
    },
  ],
});
