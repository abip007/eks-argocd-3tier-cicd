// CORS origin is chosen when app.js loads, so each case loads a fresh copy.
jest.mock('../src/db', () => ({ query: jest.fn() }));
const request = require('supertest');

function loadApp(env) {
  const saved = { ...process.env };
  Object.assign(process.env, env);
  let app;
  jest.isolateModules(() => { app = require('../src/app'); });
  process.env = saved;
  return app;
}

const origin = (res) => res.headers['access-control-allow-origin'];

test('production allows only FRONTEND_URL', async () => {
  const app = loadApp({ NODE_ENV: 'production', FRONTEND_URL: 'https://cicd-bmi.example.com' });
  const res = await request(app).get('/health').set('Origin', 'https://cicd-bmi.example.com');
  expect(origin(res)).toBe('https://cicd-bmi.example.com');
  expect(res.body.environment).toBe('production');
});

test('production without FRONTEND_URL falls back to http://localhost', async () => {
  delete process.env.FRONTEND_URL;
  const app = loadApp({ NODE_ENV: 'production' });
  const res = await request(app).get('/health').set('Origin', 'http://localhost');
  expect(origin(res)).toBe('http://localhost');
});

test('development allows the Vite dev server', async () => {
  const app = loadApp({ NODE_ENV: 'development' });
  const res = await request(app).get('/health').set('Origin', 'http://localhost:5173');
  expect(origin(res)).toBe('http://localhost:5173');
});
