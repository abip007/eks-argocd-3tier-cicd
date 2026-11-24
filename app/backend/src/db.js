const { Pool } = require('pg');
const log = require('./log');

// PostgreSQL connection pool configuration
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 20, // Maximum number of clients in the pool
  idleTimeoutMillis: 30000, // Close idle clients after 30 seconds
  connectionTimeoutMillis: 2000, // Return error after 2 seconds if can't connect
});

// Handle pool errors
pool.on('error', (err, client) => {
  log('error', 'idle PostgreSQL client error', { error: err.message });
  process.exit(-1);
});

// Test connection on startup
pool.query('SELECT NOW()', (err, res) => {
  if (err) {
    log('error', 'database connection failed', { error: err.message });
    process.exit(1);
  } else {
    log('info', 'database connected', { now: res.rows[0].now });
  }
});

module.exports = {
  query: (text, params) => pool.query(text, params),
  pool
};