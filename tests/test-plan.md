# Test Plan

Covers the application, the pipeline's compliance gates, and the
infrastructure's compliance posture. The goal is not just "does the app
work" but "can the pipeline structurally prevent an unsigned, unapproved,
or unauditable artifact from reaching production."

## Unit tests (application code, runs in `build-test-lint` job)

- Standard application logic coverage (business rules, request handlers).
- Target: existing framework test runner (`npm test`), coverage report
  uploaded as an evidence artifact.
- Owner: application developers, run on every push/PR.

## Contract tests (staging, runs in `deploy-staging` job)

- Validate the deployed API surface matches the expected OpenAPI/contract
  spec — catches breaking changes before they reach production, independent
  of unit-test coverage of internal logic.
- Example: `smoke-test.sh` validates health endpoint shape, auth-required
  routes reject unauthenticated requests, and response schema for a core
  read endpoint.

## Integration tests — pipeline compliance gates

These validate the *pipeline itself*, not the application. Run manually or
in a scheduled workflow against a sandbox Azure subscription, since they
intentionally try to violate the compliance gates.

| Test | Steps | Expected result |
|---|---|---|
| Unsigned artifact cannot deploy | Attempt `az containerapp update` with an unsigned image digest using the `ci-deploy-production` service principal | `cosign verify` step fails in `deploy-staging`; revision never updates |
| Approval without change ticket is rejected | Approve the `production` environment deployment with a comment lacking a `CHG-####` pattern | `change-ticket-gate` job fails; `deploy-production` never runs |
| CI build identity cannot touch evidence immutability config | Attempt to modify the evidence container's immutability policy using the `ci-build` or `ci-deploy-production` service principal credentials | `AuthorizationFailed` — blocked by the custom RBAC role's limited action set plus the deny-effect Policy assignment |
| CI identity cannot delete evidence blobs | Attempt `az storage blob delete` on an object in the evidence container using pipeline credentials | Blocked by the immutability policy (Locked state) regardless of RBAC, and additionally denied by the custom RBAC role's action set |
| Non-approver cannot bypass environment gate | Attempt to trigger `deploy-production` job without an environment approval | GitHub blocks job start; the federated identity credential's subject condition (`environment:production`) means Entra ID never issues an access token for a job outside the protected environment |
| Policy drift is detected | Manually assign an over-broad role (e.g., Owner) to the CI service principal, then wait for the next Policy evaluation cycle | The custom no-standing-owner-role-assignment policy transitions to NonCompliant; `compliance-check` job fails on next pipeline run |
| Evidence record completeness | Run a full pipeline to production; inspect the evidence container | Both `build-scan-sign.json` and `production-deploy.json` exist for the commit SHA, with `chain-of-custody=complete` metadata on the latter |

## Infrastructure / IaC tests

- `terraform validate` and `terraform plan` on every change to
  `infra-as-code/*.tf` (recommend adding as a CI job, not included in
  `pipeline.yml` above since that pipeline targets the application repo;
  a mirrored `terraform-plan.yml` workflow on the infra repo is the natural
  home for this).
- `checkov` or `tfsec` static analysis on the Terraform to catch drift from
  security best practices (e.g., someone accidentally disabling
  `public_network_access_enabled = false` on the evidence storage account
  in a future PR).

## Manual / periodic tests

- **Quarterly game day:** simulate a compromised CI credential and confirm
  the custom RBAC role plus resource locks and deny-effect Policy
  assignments hold; simulate an evidence-container write failure and
  confirm the alert in `monitoring-logging-alerting.md` fires and the
  runbook procedure produces a correctly backfilled record. Also exercise
  the pipeline-scripted rollback explicitly, since (unlike ECS) Container
  Apps has no infra-native circuit breaker to fall back on if the script
  itself has a bug — this game day is the primary way that gap gets
  caught before a real incident does.
- **Annual audit dry run:** compliance officer queries the evidence
  container for 5 randomly selected historical deploys and confirms full
  commit-to-production traceability is reconstructable in under 5 minutes
  each, validating the target metric in `README.md`.

## Example validation commands

See `tests/smoke-test.sh` for a runnable example covering the staging
contract-test step referenced above.
