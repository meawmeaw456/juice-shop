# DevSecOps Pipeline OWASP Juice Shop

A single GitHub Actions pipeline that scans the app on every push/PR and gates
deployment on **one** security decision. Findings are pushed to **DefectDojo**,
which feeds the Security-console web app.

Ce pipeline alimente DefectDojo, consommé par la console [Security-console](https://github.com/meawmeaw456/security-console).

```
CI (this pipeline)  ->  DefectDojo  ->  Security-console  ->  Jira
```

GitHub is not connected to Secureity-console directly: scan results flow through
DefectDojo, the source of truth for findings.

---

## How it works

Four scans run **in parallel** and only upload their reports; none of them
decides pass/fail on its own. A single `quality-gate` job then downloads every
report and applies all policies in one place.

```
build-and-scan-image   semgrep-sast   trivy-fs   trivy-config   (parallel)
                    \        |            |           /
                         quality-gate   ── PASS -> READY FOR DEPLOYMENT
                         (single gate)     FAIL -> NOT READY FOR DEPLOYMENT
                              |
                        import-defectdojo  (records findings, push only)
```

| Job | Tool | Output |
|---|---|---|
| `build-and-scan-image` | Trivy image scan + CycloneDX SBOM | `trivy-image.sarif`, `sbom.cdx.json` |
| `semgrep-sast` | Semgrep (one scan) | `semgrep.sarif`, `semgrep.json` |
| `trivy-fs` | Trivy filesystem (secrets) | `trivy-fs.sarif` |
| `trivy-config` | Trivy config (IaC / Dockerfile) | `trivy-config.sarif` |
| `quality-gate` | jq policy evaluation | the single PASS/FAIL decision |
| `import-defectdojo` | `curl` reimport | findings in DefectDojo |

All SARIF is also uploaded to the repository's **Security** tab.

### The single quality gate

The gate blocks the pipeline (`exit 1`) if any of these is violated:

| Category | Blocks when | How it is counted |
|---|---|---|
| Image vulnerabilities | any CRITICAL/HIGH (fixable) | SARIF results with `level == "error"` |
| SAST (Semgrep) | any `ERROR` finding | `results[].extra.severity == "ERROR"` |
| Secrets | any secret detected | number of results in the secrets SARIF |
| IaC / config | any CRITICAL/HIGH misconfig | SARIF results with `level == "error"` |

This uses Trivy's own severity-to-SARIF mapping: **CRITICAL/HIGH → `error`**,
MEDIUM → `warning`, LOW → `note`. Counting `level == "error"` therefore equals
the count of CRITICAL + HIGH. If an *enabled* scan produces **no** report (the
scanner crashed), the gate fails on purpose — a missing scan is not a pass.

> Why one gate and not four inline ones: a single decision point is easier to
> read, audit and change, and it lets secrets and IaC block the deploy too
> (the earlier inline setup only blocked on image vulns and Semgrep).

### DefectDojo import

`import-defectdojo` runs on **push** events, independently of the gate result,
so DefectDojo (and therefore Security-console) is populated even when the deploy is
blocked. It needs two repository secrets (below). If they are absent, the job
logs a warning and skips — the rest of the pipeline still runs.

---

## Required repository secrets

| Secret | Needed for | Example |
|---|---|---|
| `DEFECTDOJO_URL` | DefectDojo import | `https://defectdojo.example.com` |
| `DEFECTDOJO_TOKEN` | DefectDojo import | DefectDojo API v2 token |

Set them under **Repo → Settings → Secrets and variables → Actions**. No secret
is ever written in the workflow file.

---

## Reuse in another project

This is a normal workflow file — copy it and change a few clearly marked values.

1. Copy `.github/workflows/main.yml` into the other repository.

2. Edit the **`env:` block** at the top of the file:

   ```yaml
   env:
     IMAGE_REF: myapp:ci             # image tag to build & scan
     DOCKERFILE: Dockerfile          # path to the Dockerfile
     DD_PRODUCT: "My App"            # DefectDojo product name
     DD_ENGAGEMENT: "Automated Scans"
   ```

3. Adjust the branches under `on:` if the repo uses `main` instead of `master`.

4. Add the two DefectDojo secrets (above) if you want the import.

5. Adjust anything project-specific:
   - **Semgrep `--exclude` paths** (in the `Run Semgrep` step) to match the repo
     layout, and `--config` if you want a different ruleset than
     `p/owasp-top-ten`.
   - If the repo has **no Dockerfile**, remove the `build-and-scan-image` job and
     its entry in the two `needs:` lists (`quality-gate`, `import-defectdojo`).

### Requirements in the consuming repo

- A **`Dockerfile`** (the image job runs `docker build`), unless you remove that job.
- Nothing to install: `jq` is pre-installed on GitHub-hosted Ubuntu runners.
- The workflow already grants each job `security-events: write` so SARIF can be
  uploaded to the Security tab — no extra permissions setup needed.

### Change the gate policy

- **Report-only** for a category: in `quality-gate`, replace its
  `[ "$N" -gt 0 ] && fail "..."` with just `echo` (it will print the count but
  not block).
- **Block on MEDIUM too:** also count `warning`, e.g.
  `select(.level=="error" or .level=="warning")`.
- **Block on CRITICAL only:** produce the SARIF with Trivy's `severity: CRITICAL`
  and `limit-severities-for-sarif: true`, then count all results.

---

## Pinned actions

Every third-party action is pinned by commit SHA (the comment shows the
human-readable version), so a moved tag can't change what runs:

| Action | Version |
|---|---|
| `step-security/harden-runner` | v2.20.1 |
| `actions/checkout` | v7.0.0 |
| `actions/setup-python` | v6.0.0 |
| `aquasecurity/trivy-action` | v0.36.0 |
| `github/codeql-action/upload-sarif` | v4.37.1 |
| `actions/upload-artifact` | v7.0.1 |
| `actions/download-artifact` | v8.0.1 |

---

## Validate it on a first run

The gate logic (severity counting, PASS/FAIL) has been checked against
representative Trivy SARIF and Semgrep JSON. What can only be confirmed on a
real run because it depends on your runners, image and DefectDojo instance 
is the full round-trip. Quick check: introduce a known **fixable HIGH**
vulnerability in the image and confirm the run ends with
`NOT READY FOR DEPLOYMENT` (gate fails); with a clean tree it should end with
`READY FOR DEPLOYMENT`.
