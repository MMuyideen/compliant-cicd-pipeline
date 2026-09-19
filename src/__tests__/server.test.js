const request = require("supertest");
const { createApp } = require("../server");

const app = createApp();

describe("GET /healthz", () => {
  it("returns 200 with status ok", async () => {
    const res = await request(app).get("/healthz");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: "ok" });
  });

  it("includes security headers", async () => {
    const res = await request(app).get("/healthz");
    expect(res.headers["strict-transport-security"]).toBeDefined();
    expect(res.headers["x-content-type-options"]).toBe("nosniff");
  });
});

describe("GET /api/patients", () => {
  it("rejects requests without an Authorization header", async () => {
    const res = await request(app).get("/api/patients");
    expect(res.status).toBe(401);
  });

  it("allows requests with an Authorization header", async () => {
    const res = await request(app)
      .get("/api/patients")
      .set("Authorization", "Bearer test-token");
    expect(res.status).toBe(200);
  });
});
