require('dotenv').config();
const app = require('./app');
const log = require('./log');

const PORT = process.env.PORT || 3000;

app.listen(PORT, () => {
  log('info', 'server started', {
    port: Number(PORT), environment: process.env.NODE_ENV || 'development', version: process.env.APP_VERSION || 'dev',
  });
});
