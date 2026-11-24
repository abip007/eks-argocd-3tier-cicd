// Structured logging: one JSON object per line on stdout (errors on stderr).
// Grafana Alloy collects pod output and ships it to Loki, where `| json` turns
// every field into something you can filter on, e.g.
//   {namespace="bmi-cicd", app="bmi-backend"} | json | level="error"
module.exports = function log(level, msg, fields = {}) {
  const line = JSON.stringify({ time: new Date().toISOString(), level, msg, ...fields });
  if (level === 'error') console.error(line);
  else console.log(line);
};
