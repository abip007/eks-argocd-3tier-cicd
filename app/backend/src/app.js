// Express app without app.listen(), so tests can import it (supertest) and
// server.js can start it. Keep every route and middleware here.
const express = require('express');
const bodyParser = require('body-parser');
const cors = require('cors');
const client = require('prom-client');
const routes = require('./routes');
const log = require('./log');

const NODE_ENV = process.env.NODE_ENV || 'development';

// ---------- Observability ----------
// Metrics for Prometheus (scraped from /metrics by gitops/bmi-cicd/base/servicemonitor.yaml):
//  - Node.js runtime metrics: CPU, memory, event loop lag, GC ("process_*", "nodejs_*")
//  - http_request_duration_seconds: histogram per method, route and status code.
//    Request rate, error rate and latency percentiles are all derived from it.
// Own registry, so requiring the app twice (tests) doesn't register a metric twice.
const register = new client.Registry();
client.collectDefaultMetrics({ register });
const httpDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});
// Which release is live: APP_VERSION is the image tag the pipeline's BuildPush wrote into
// gitops/. Grafana shows it per pod, so every deploy appears on the dashboard.
new client.Gauge({
  name: 'bmi_app_info',
  help: 'Always 1; the version label is the deployed release (image tag)',
  labelNames: ['version'],
  registers: [register],
}).set({ version: process.env.APP_VERSION || 'dev' }, 1);

const app = express();
app.disable('x-powered-by'); // don't advertise the framework/version (SonarQube S5689)

// One histogram sample and one JSON log line per request. Probes and scrapes are skipped:
// they'd drown the real traffic. Alloy ships stdout to Loki, where
// {app="bmi-backend"} | json | status >= 500 filters on these fields.
app.use((req, res, next) => {
  if (req.path === '/metrics' || req.path === '/health') return next();
  const end = httpDuration.startTimer();
  const started = Date.now();
  res.on('finish', () => {
    // Route pattern (/api/measurements/:id), not the raw URL: keeps label values few.
    const route = req.route ? req.baseUrl + req.route.path : 'unmatched';
    end({ method: req.method, route, status_code: res.statusCode });
    log(res.statusCode >= 500 ? 'error' : 'info', 'request', {
      method: req.method, route, status: res.statusCode, duration_ms: Date.now() - started,
    });
  });
  next();
});

// Only reachable inside the cluster: the ALB/nginx route /api/* to the backend, not /metrics.
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.use(cors({
  origin: NODE_ENV === 'production'
    ? process.env.FRONTEND_URL || 'http://localhost'
    : ['http://localhost:5173', 'http://localhost:3000'],
  credentials: true,
  optionsSuccessStatus: 200
}));
app.use(bodyParser.json());

// Kubernetes probes hit this one directly on the pod (no DB check, so a DB
// blip does not restart every pod).
app.get('/health', (req, res) => {
  res.json({ status: 'ok', environment: NODE_ENV });
});

app.use('/api', routes);

app.use((req, res) => {
  res.status(404).json({ error: 'Route not found' });
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  log('error', 'unhandled error', { error: err.message, stack: err.stack });
  res.status(500).json({ error: 'Internal server error' });
});

module.exports = app;
module.exports.register = register; // tests read the metrics directly
