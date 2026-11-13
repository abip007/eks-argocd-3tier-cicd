import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: 'http://localhost:3000',
        changeOrigin: true
      }
    }
  },
  // Vitest (npm test). Coverage goes to coverage/lcov.info, which SonarQube reads.
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./tests/setup.js'],
    include: ['tests/**/*.test.{js,jsx}'],
    reporters: ['default', 'junit'],
    outputFile: { junit: 'reports/junit.xml' },
    coverage: {
      provider: 'v8',
      include: ['src/**/*.{js,jsx}'],
      exclude: ['src/main.jsx'],
      reporter: ['text', 'lcov', 'cobertura'],
      reportsDirectory: 'coverage',
      thresholds: { statements: 80, branches: 80, functions: 80, lines: 80 }
    }
  }
});
