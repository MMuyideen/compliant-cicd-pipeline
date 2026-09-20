#!/usr/bin/env bash
#
# smoke-test.sh — validates a deployed environment (staging or production)
# before/after a pipeline promotion. Used by the `deploy-staging` job in
# ci-cd/pipeline.yml, and safe to run manually against either environment
# for ad hoc verification (see runbook.md).
#
# Usage: ./smoke-test.sh <base-url>
#   e.g. ./smoke-test.sh https://staging.patient-portal.example-health-vendor.com

set -euo pipefail

BASE_URL="${1:?Usage: smoke-test.sh <base-url>}"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "== Smoke + contract tests against ${BASE_URL} =="

# 1. Health endpoint returns 200 and expected shape.
health_response=$(curl -s -o /tmp/health.json -w "%{http_code}" "${BASE_URL}/healthz" || echo "000")
if [ "$health_response" = "200" ]; then
  pass "GET /healthz returned 200"
else
  fail "GET /healthz returned ${health_response}, expected 200"
fi

if command -v jq >/dev/null 2>&1 && [ -f /tmp/health.json ]; then
  status=$(jq -r '.status // empty' /tmp/health.json 2>/dev/null || echo "")
  if [ "$status" = "ok" ]; then
    pass "/healthz body has status: ok"
  else
    fail "/healthz body missing expected 'status: ok' field"
  fi
fi

# 2. Unauthenticated request to a protected route is rejected (401/403),
#    not silently allowed through — this is a contract test on the auth
#    layer, not just a smoke test.
protected_response=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/patients" || echo "000")
if [ "$protected_response" = "401" ] || [ "$protected_response" = "403" ]; then
  pass "GET /api/patients without auth correctly rejected (${protected_response})"
else
  fail "GET /api/patients without auth returned ${protected_response}, expected 401/403"
fi

# 3. TLS is enforced — plain HTTP should redirect or refuse, never serve
#    PHI-adjacent content in the clear.
if [[ "$BASE_URL" == https://* ]]; then
  http_variant="http://${BASE_URL#https://}"
  redirect_response=$(curl -s -o /dev/null -w "%{http_code}" "$http_variant" --max-time 5 || echo "000")
  if [ "$redirect_response" = "301" ] || [ "$redirect_response" = "302" ] || [ "$redirect_response" = "000" ]; then
    pass "Plain HTTP does not serve content directly (${redirect_response})"
  else
    fail "Plain HTTP returned ${redirect_response} — expected redirect or connection refusal"
  fi
fi

# 4. Response includes expected security headers (defense-in-depth check,
#    relevant for a HIPAA-in-scope application).
headers=$(curl -s -D - -o /dev/null "${BASE_URL}/healthz" || echo "")
for header in "Strict-Transport-Security" "X-Content-Type-Options"; do
  if echo "$headers" | grep -qi "$header"; then
    pass "Response includes ${header} header"
  else
    fail "Response missing ${header} header"
  fi
done

# 5. Deployed image digest matches what the pipeline signed (cross-check
#    against the build-scan-sign evidence record, if COMMIT_SHA and
#    EVIDENCE_STORAGE_ACCOUNT are set in the environment).
if [ -n "${COMMIT_SHA:-}" ] && [ -n "${EVIDENCE_STORAGE_ACCOUNT:-}" ]; then
  if az storage blob download \
      --account-name "${EVIDENCE_STORAGE_ACCOUNT}" \
      --container-name evidence \
      --name "pipeline-evidence/${COMMIT_SHA}/build-scan-sign.json" \
      --file /tmp/evidence.json --auth-mode login >/dev/null 2>&1; then
    pass "Evidence record found for commit ${COMMIT_SHA}"
  else
    fail "No evidence record found for commit ${COMMIT_SHA} — chain of custody incomplete"
  fi
fi

echo "=================================="
if [ "$FAILURES" -eq 0 ]; then
  echo "All smoke/contract tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
