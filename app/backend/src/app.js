// Express app without app.listen(), so tests can import it (supertest) and
// server.js can start it. Keep every route and middleware here.
const express = require('express');
const bodyParser = require('body-parser');
const cors = require('cors');
const routes = require('./routes');

const NODE_ENV = process.env.NODE_ENV || 'development';

const app = express();
app.disable('x-powered-by'); // don't advertise the framework/version (SonarQube S5689)

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
  console.error('Server error:', err);
  res.status(500).json({ error: 'Internal server error' });
});

module.exports = app;
