# Demo Data

Synthetic data to seed a demo of the pipeline and evidence store — no real
PHI, ever. Use this to demonstrate the "query the evidence container, get a
complete chain of custody in minutes" story without needing a live Azure
subscription wired to a real GitHub repo.

## What to generate

1. **Synthetic change tickets** (`CHG-1001` through `CHG-1010`) — a small
   JSON or CSV list simulating a change-management system export:
   ```json
   { "ticket_id": "CHG-1001", "title": "Fix patient search pagination bug", "requested_by": "jdoe", "approved_by": "msmith", "risk_tier": "standard" }
   ```

2. **Synthetic evidence records** — mimic the JSON emitted by
   `ci-cd/pipeline.yml`'s "Emit evidence record" steps, for ~10 fake
   deploys, so the evidence bucket has something to query during a demo.

## Generator script (run locally, writes to ./demo-data/output/)

```bash
#!/usr/bin/env bash
set -euo pipefail
mkdir -p output

for i in $(seq 1001 1010); do
  commit_sha=$(openssl rand -hex 20)
  digest="sha256:$(openssl rand -hex 32)"
  ts=$(date -u -v-"$((RANDOM % 30))"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
       date -u -d "-$((RANDOM % 30)) days" +%Y-%m-%dT%H:%M:%SZ)

  cat > "output/CHG-${i}.json" <<EOF
{
  "ticket_id": "CHG-${i}",
  "title": "Synthetic demo change ${i}",
  "requested_by": "demo-engineer",
  "approved_by": "demo-approver",
  "risk_tier": "standard"
}
EOF

  mkdir -p "output/pipeline-evidence/${commit_sha}"
  cat > "output/pipeline-evidence/${commit_sha}/build-scan-sign.json" <<EOF
{
  "stage": "build-scan-sign",
  "commit_sha": "${commit_sha}",
  "image_digest": "${digest}",
  "workflow_run_id": "${i}00",
  "actor": "demo-engineer",
  "timestamp": "${ts}",
  "signed": true
}
EOF

  cat > "output/pipeline-evidence/${commit_sha}/production-deploy.json" <<EOF
{
  "stage": "production-deploy",
  "commit_sha": "${commit_sha}",
  "image_digest": "${digest}",
  "change_ticket": "CHG-${i}",
  "approver": "demo-approver",
  "workflow_run_id": "${i}00",
  "deployed_at": "${ts}"
}
EOF
done

echo "Generated 10 synthetic change tickets and evidence records under output/"
```

Save this as `generate-demo-data.sh`, `chmod +x` it, and run it locally.
It requires only `bash` and `openssl` (both present by default on macOS/Linux).

## Seeding a real (sandbox) evidence container for a live demo

```bash
az storage blob upload-batch \
  --account-name <your-sandbox-evidence-account> \
  --destination evidence \
  --source output/pipeline-evidence \
  --destination-path pipeline-evidence \
  --auth-mode login
```

Only ever point this at a sandbox storage account — never at a real
evidence container with genuine audit history, since the container's
immutability policy in Locked state means these synthetic records would
become undeletable for the full retention period.

## Demo script suggestion

1. Show the synthetic change ticket `CHG-1005.json`.
2. Query the evidence bucket for the matching `production-deploy.json` and
   walk through commit SHA -> image digest -> approver -> ticket link.
3. Time how long that took (should be seconds) — this is the "audit
   evidence generation: 1-3 days -> under 5 minutes" metric from
   `README.md`, demonstrated live.
