const express = require("express");
const helmet = require("helmet");

function createApp() {
  const app = express();

  // HSTS + X-Content-Type-Options etc. — smoke-test.sh asserts these are
  // present on every response, since this app is HIPAA-in-scope.
  app.use(helmet());

  app.get("/healthz", (req, res) => {
    res.status(200).json({ status: "ok" });
  });

  // Stand-in for the real auth middleware: rejects unauthenticated
  // requests to PHI-adjacent routes rather than serving them.
  app.get("/api/patients", (req, res) => {
    if (!req.headers.authorization) {
      return res.status(401).json({ error: "unauthorized" });
    }
    res.status(200).json({ patients: [] });
  });

  return app;
}

module.exports = { createApp };
