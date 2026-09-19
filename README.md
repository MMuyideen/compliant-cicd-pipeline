**Primary cloud provider(s):** Azure (GitHub Actions as CI/CD orchestrator + Azure for runtime, evidence storage, and compliance tooling)
**Difficulty:** Intermediate-Advanced
**Bloom level targeted:** 5 (Evaluation)
**Estimated time:** 20-25 hours
**Key skills practiced:** CI/CD design, compliance-as-code, audit-trail engineering, RBAC/least-privilege identity design, artifact signing/supply-chain security, change-management integration, cost/risk trade-off analysis

## Purpose

This project redesigns the deployment pipeline for a healthcare software vendor that handles Protected Health Information (PHI) and is subject to HIPAA plus internal SOX-like change-control requirements. It replaces a manual, undocumented deploy process with a fully automated, cryptographically auditable CI/CD pipeline that enforces separation of duties, records an immutable chain of custody from commit to production, and cuts release lead time by an order of magnitude.

## Business problem solved

The vendor currently ships releases by having a developer manually SCP a build artifact to a production server and restart the service. There is no artifact signing, no automated testing gate, and no reliable link between a deployed binary and the change ticket that approved it. Each release requires 2-3 weeks of manual change-approval paperwork, and a HIPAA or SOC 2 auditor cannot reconstruct "who approved what, and is what's running in production actually what was approved" without manually cross-referencing emails, tickets, and server shell history. This is both a compliance liability (audit findings, potential breach-notification exposure) and a competitive one (slow release cadence versus competitors shipping fixes same-day).

## Target users/customers

- Internal: platform/DevOps engineers, compliance/security officers, engineering managers who own change-approval SLAs.
- External (indirect): healthcare provider customers who require SOC 2 / HIPAA attestations as part of procurement, and whose patient-safety-critical bug fixes are currently delayed by the 2-3 week release cycle.

## Expected outcomes

- Every production deploy is traceable: commit SHA -> PR review -> CI test/scan results -> signed artifact -> staging validation -> named human approver -> change-ticket ID -> production deploy timestamp, stored immutably.
- Deployment lead time drops from 2-3 weeks to under 24 hours for a standard change, and under 1 hour for an emergency/break-glass change (with mandatory post-hoc review).
- Unsigned or unapproved artifacts are structurally incapable of reaching production (enforced by pipeline, not policy memo).
- Audit evidence generation (for HIPAA Security Rule §164.312(b) audit controls and SOC 2 CC7/CC8) becomes a query against an evidence store instead of a multi-day manual reconstruction effort.

## Metrics to measure success

| Metric | Baseline | Target |
|---|---|---|
| Deployment lead time (commit to prod) | 2-3 weeks | < 24 hours (standard), < 1 hour (break-glass) |
| % of deploys with complete audit trail | ~0% (manual/undocumented) | 100% |
| Unauthorized/unsigned deploy attempts reaching prod | Unknown (unmeasured) | 0 |
| Time to produce audit evidence for a given deploy | 1-3 days (manual) | < 5 minutes (query) |
| Mean time to rollback | Unmeasured, ad hoc | < 10 minutes |
