// /metrics (Prometheus) and the JSON request logs (Loki). The database is mocked.
jest.mock('../src/db', () => ({ query: jest.fn() }));

const request = require('supertest');
const db = require('../src/db');
const app = require('../src/app');
const log = require('../src/log');

let out, err;
beforeEach(() => {
  db.query.mockReset();
  out = jest.spyOn(console, 'log').mockImplementation(() => {});
  err = jest.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => jest.restoreAllMocks());

const lines = (spy) => spy.mock.calls.map(([l]) => JSON.parse(l));

describe('GET /metrics', () => {
  test('serves Prometheus text with Node.js runtime metrics', async () => {
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/^text\/plain/);
    expect(res.text).toMatch(/^# HELP process_cpu_user_seconds_total/m);
    expect(res.text).toMatch(/^nodejs_eventloop_lag_seconds /m);
  });

  test('bmi_app_info reports the deployed version (APP_VERSION)', async () => {
    let fresh;
    process.env.APP_VERSION = 'abc1234-9';
    jest.isolateModules(() => { fresh = require('../src/app'); });
    delete process.env.APP_VERSION;
    expect(await fresh.register.getSingleMetricAsString('bmi_app_info')).toMatch(/bmi_app_info\{version="abc1234-9"\} 1/);
    expect(await app.register.getSingleMetricAsString('bmi_app_info')).toMatch(/bmi_app_info\{version="dev"\} 1/);
  });

  test('counts API requests by route pattern and status code', async () => {
    db.query.mockResolvedValue({ rows: [] });
    await request(app).get('/api/measurements');
    await request(app).get('/nope');
    const metrics = await app.register.getSingleMetricAsString('http_request_duration_seconds');
    expect(metrics).toMatch(/http_request_duration_seconds_count\{method="GET",route="\/api\/measurements",status_code="200"\} [1-9]/);
    expect(metrics).toMatch(/http_request_duration_seconds_count\{method="GET",route="unmatched",status_code="404"\} [1-9]/);
  });

  test('probes and scrapes are not counted or logged', async () => {
    await request(app).get('/health');
    await request(app).get('/metrics');
    const metrics = await app.register.getSingleMetricAsString('http_request_duration_seconds');
    expect(metrics).not.toMatch(/route="\/health"/);
    expect(metrics).not.toMatch(/route="\/metrics"/);
    expect(out).not.toHaveBeenCalled();
  });
});

describe('JSON request logs', () => {
  test('one info line per request, with route, status and duration', async () => {
    db.query.mockResolvedValue({ rows: [] });
    await request(app).get('/api/measurements');
    const [line] = lines(out);
    expect(line).toMatchObject({ level: 'info', msg: 'request', method: 'GET', route: '/api/measurements', status: 200 });
    expect(typeof line.duration_ms).toBe('number');
    expect(Date.parse(line.time)).not.toBeNaN();
  });

  test('5xx responses are logged at level error on stderr', async () => {
    db.query.mockRejectedValue(new Error('db down'));
    await request(app).get('/api/measurements');
    const errors = lines(err);
    expect(errors).toContainEqual(expect.objectContaining({ level: 'error', msg: 'fetch measurements failed', error: 'db down' }));
    expect(errors).toContainEqual(expect.objectContaining({ level: 'error', msg: 'request', status: 500 }));
  });

  test('log() writes valid JSON and keeps extra fields', () => {
    log('warn', 'something', { a: 1 });
    expect(lines(out)[0]).toMatchObject({ level: 'warn', msg: 'something', a: 1 });
    log('info', 'no fields');
    expect(Object.keys(lines(out)[1]).sort()).toEqual(['level', 'msg', 'time']);
  });
});
