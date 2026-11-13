import { vi } from 'vitest';
import api from '../src/api';

// Call the interceptors directly; no network involved.
const req = api.interceptors.request.handlers[0];
const res = api.interceptors.response.handlers[0];

beforeEach(() => vi.spyOn(console, 'error').mockImplementation(() => {}));

describe('api client', () => {
  test('sends requests to /api as JSON with a 10 s timeout', () => {
    expect(api.defaults.baseURL).toBe('/api');
    expect(api.defaults.timeout).toBe(10000);
    expect(api.defaults.headers['Content-Type']).toBe('application/json');
  });

  test('request interceptor passes config through and rejects errors', async () => {
    const cfg = { url: '/x' };
    expect(req.fulfilled(cfg)).toBe(cfg);
    await expect(req.rejected(new Error('bad'))).rejects.toThrow('bad');
  });

  test('response interceptor passes responses through', () => {
    const r = { status: 200 };
    expect(res.fulfilled(r)).toBe(r);
  });

  test.each([
    ['server error', { response: { status: 500, data: {} } }, 'API Error:'],
    ['no response', { request: {} }, 'Network Error: No response from server'],
    ['other', { message: 'oops' }, 'Error:']
  ])('response interceptor logs %s and rejects', async (_, err, logged) => {
    await expect(res.rejected(err)).rejects.toBe(err);
    expect(console.error.mock.calls[0][0]).toBe(logged);
  });
});
