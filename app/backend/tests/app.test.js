// HTTP tests for every route. The database is mocked, so no Postgres is needed.
jest.mock('../src/db', () => ({ query: jest.fn() }));

const request = require('supertest');
const db = require('../src/db');
const app = require('../src/app');

const valid = { weightKg: 70, heightCm: 175, age: 30, sex: 'male', activity: 'moderate', measurementDate: '2026-01-15' };

beforeEach(() => {
  db.query.mockReset();
  jest.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => jest.restoreAllMocks());

describe('health', () => {
  test('GET /health returns ok without touching the database', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
    expect(res.headers['x-powered-by']).toBeUndefined();
    expect(db.query).not.toHaveBeenCalled();
  });

  test('GET /api/health reports version and database up', async () => {
    process.env.APP_VERSION = 'abc1234-7';
    db.query.mockResolvedValue({ rows: [{ '?column?': 1 }] });
    const res = await request(app).get('/api/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok', version: 'abc1234-7', database: 'up' });
    delete process.env.APP_VERSION;
  });

  test('GET /api/health returns 503 and version "dev" when the database is down', async () => {
    db.query.mockRejectedValue(new Error('ECONNREFUSED'));
    const res = await request(app).get('/api/health');
    expect(res.status).toBe(503);
    expect(res.body).toEqual({ status: 'degraded', version: 'dev', database: 'down' });
  });
});

describe('POST /api/measurements', () => {
  test('stores the measurement with calculated metrics and returns 201', async () => {
    db.query.mockImplementation((sql, values) => Promise.resolve({ rows: [{ id: 1, values }] }));
    const res = await request(app).post('/api/measurements').send(valid);

    expect(res.status).toBe(201);
    const [sql, values] = db.query.mock.calls[0];
    expect(sql).toMatch(/INSERT INTO measurements/);
    expect(values).toEqual([70, 175, 30, 'male', 'moderate', 22.9, 'Normal', 1649, 2556, '2026-01-15']);
    expect(res.body.measurement.id).toBe(1);
  });

  test('defaults measurement date to today', async () => {
    db.query.mockResolvedValue({ rows: [{ id: 2 }] });
    const { measurementDate, ...noDate } = valid;
    await request(app).post('/api/measurements').send(noDate);
    expect(db.query.mock.calls[0][1][9]).toBe(new Date().toISOString().split('T')[0]);
  });

  test.each(['weightKg', 'heightCm', 'age', 'sex'])('returns 400 when %s is missing', async (field) => {
    const body = { ...valid };
    delete body[field];
    const res = await request(app).post('/api/measurements').send(body);
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Missing required fields');
    expect(db.query).not.toHaveBeenCalled();
  });

  test('returns 400 for negative values', async () => {
    const res = await request(app).post('/api/measurements').send({ ...valid, weightKg: -5 });
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/positive/);
  });

  test('returns 500 with the database error message', async () => {
    db.query.mockRejectedValue(new Error('insert failed'));
    const res = await request(app).post('/api/measurements').send(valid);
    expect(res.status).toBe(500);
    expect(res.body.error).toBe('insert failed');
  });

  test('returns 500 with a generic message when the error has none', async () => {
    db.query.mockRejectedValue(new Error(''));
    const res = await request(app).post('/api/measurements').send(valid);
    expect(res.status).toBe(500);
    expect(res.body.error).toBe('Failed to create measurement');
  });
});

describe('GET /api/measurements', () => {
  test('returns rows newest first', async () => {
    db.query.mockResolvedValue({ rows: [{ id: 2 }, { id: 1 }] });
    const res = await request(app).get('/api/measurements');
    expect(res.status).toBe(200);
    expect(res.body.rows).toHaveLength(2);
    expect(db.query.mock.calls[0][0]).toMatch(/ORDER BY measurement_date DESC/);
  });

  test('returns 500 on database error', async () => {
    db.query.mockRejectedValue(new Error('boom'));
    const res = await request(app).get('/api/measurements');
    expect(res.status).toBe(500);
    expect(res.body.error).toBe('Failed to fetch measurements');
  });
});

describe('GET /api/measurements/trends', () => {
  test('returns the 30-day averages', async () => {
    db.query.mockResolvedValue({ rows: [{ day: '2026-01-01', avg_bmi: '22.5' }] });
    const res = await request(app).get('/api/measurements/trends');
    expect(res.status).toBe(200);
    expect(res.body.rows[0].avg_bmi).toBe('22.5');
    expect(db.query.mock.calls[0][0]).toMatch(/30 days/);
  });

  test('returns 500 on database error', async () => {
    db.query.mockRejectedValue(new Error('boom'));
    const res = await request(app).get('/api/measurements/trends');
    expect(res.status).toBe(500);
    expect(res.body.error).toBe('Failed to fetch trends');
  });
});

describe('fallbacks', () => {
  test('unknown route returns 404 JSON', async () => {
    const res = await request(app).get('/nope');
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('Route not found');
  });

  test('malformed JSON is handled by the error middleware', async () => {
    const res = await request(app)
      .post('/api/measurements')
      .set('Content-Type', 'application/json')
      .send('{"weightKg":');
    expect(res.status).toBe(500);
    expect(res.body.error).toBe('Internal server error');
  });
});
