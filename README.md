# SIP Homer 7 — Production Voice Operations Toolkit

A sanitized portfolio edition of tooling built around **Homer 7**, PostgreSQL and Linux for production SIP/VoIP operations.

This repository is intentionally **not a production mirror**. It demonstrates the engineering patterns, safety controls, automation and troubleshooting workflows developed for a real multi-site voice platform while replacing or removing organization-specific topology, addressing, provider names, usernames, domains, credentials and operational identifiers.

> **Portfolio goal:** show how an open-source SIP capture platform can be extended into an operator-facing production toolkit with observability, recovery, deployment safety and guided lifecycle automation.

## What this project demonstrates

The project evolved well beyond a set of monitoring scripts. The operational layer now covers:

- SIP KPI and call-quality analytics;
- interconnect/SBC route classification and historical reporting;
- automated PCAP ingestion and HEP delivery patterns;
- full PostgreSQL backups with immediate verification;
- real restore/deep-verification testing in disposable database instances;
- daily backup-health reporting so silence is never mistaken for success;
- emergency and deep platform health checks;
- guarded configuration/recovery concepts;
- Git-to-production deployment controls with provenance and checksums;
- curated `KNOWN_GOOD` recovery points and controlled rollback design;
- privilege-aware operator consoles;
- guided multi-interface user provisioning with safe resume behavior;
- security-sensitive audit logging without credential leakage;
- consistent terminal UX for normal, privileged and high-risk actions.

## Architecture at a glance

```text
     SIP capture sources / trace exports
                  |
                  v
        read-only shared storage
                  |
                  v
        discovery / watcher layer
                  |
                  v
      copy + validate + normalize
                  |
                  v
       PCAP -> HEP3 ingestion
                  |
                  v
          heplify-server
                  |
                  v
   PostgreSQL / TimescaleDB / Homer
          |                 |
          |                 +-------------------+
          v                                     v
     Homer GUI                         custom operations layer
                                      monitoring / analytics
                                      backup / recovery
                                      deployment / rollback
                                      user lifecycle
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the generalized design.

## Portfolio highlights

### 1. Backup verification that proves restoreability

The backup design does not stop at “the file exists”. It combines online PostgreSQL base backup, immediate manifest/checksum verification, retention safety, and a separate deep verification workflow that restores the backup into a disposable PostgreSQL instance and proves it is queryable. A lightweight daily reporter exposes backup age and restore-verification state between weekly backup runs.

**Case study:** [`Proving a Backup Actually Restores, Not Just Exists`](docs/case-studies/backup-verification.md)

### 2. SIP KPI investigation instead of assumption-driven fixes

The call-statistics layer calculates operational metrics such as ASR, PDD and call setup time across capture tiers. One production investigation followed multiple competing hypotheses before isolating the actual reason for a persistent metric discrepancy — and caught a flawed first fix before it reached production.

**Case study:** [`Chasing a Phantom 5-Point Metric Gap`](docs/case-studies/asr-investigation.md)

### 3. Safe Git-to-production deployment and recovery

The operational model adds release-engineering discipline around shell tooling:

- compare repository source against the live runtime copy;
- syntax validation before deployment;
- operator confirmation for writes;
- timestamped live backup before replacement;
- deployment ledger entries with Git commit and SHA256 provenance;
- curated `KNOWN_GOOD` restore points;
- rollback preview with checksum/provenance validation;
- no rewriting of Git history merely to make runtime rollback look clean.

**Case study:** [`Turning Shell Scripts into a Controlled Production Deployment System`](docs/case-studies/safe-deployment-and-rollback.md)

Design overview: [`docs/SAFETY_AND_RECOVERY.md`](docs/SAFETY_AND_RECOVERY.md)

### 4. Guided lifecycle across multiple account planes

User onboarding is treated as a recoverable workflow instead of a checklist of unrelated administration screens. The orchestrator preflights each account plane, explains the plan, invokes the existing guarded child workflow, verifies outcomes and safely resumes after partial completion or interruption.

The orchestration layer never handles passwords owned by the child systems.

**Case study:** [`Turning Multi-System User Creation into a Recoverable Workflow`](docs/case-studies/guided-user-provisioning.md)

Design overview: [`docs/USER_LIFECYCLE.md`](docs/USER_LIFECYCLE.md)

## Curated code worth reviewing

| Component | Engineering focus |
|---|---|
| [`homer-callstats.sh`](scripts/homer-callstats.sh) | ASR/PDD/CST analytics, explicit exclusion accounting, ingestion-lag fallback |
| [`homer-sbc-routes.sh`](scripts/homer-sbc-routes.sh) | Address-derived direction, R-URI/`rn=` route classification, visible unmatched routes |
| [`homer-db-backup.sh`](scripts/homer-db-backup.sh) | Online base backup, fail-fast prerequisites, verification-before-retention |
| [`homer-db-backup-deep-verify.sh`](scripts/homer-db-backup-deep-verify.sh) | Disposable PostgreSQL restore, WAL replay, recovery-state verification, cleanup traps |
| [`homer-db-backup-status.sh`](scripts/homer-db-backup-status.sh) | Lightweight daily recoverability/status reporting |
| [`homer-emergency-healthcheck.sh`](scripts/homer-emergency-healthcheck.sh) | Plain-language incident triage with non-blocking privilege handling |
| [`homer-deploy.sh`](scripts/homer-deploy.sh) | Diff, validation, pre-change backup, SHA256 and Git provenance ledger |
| [`homer-known-good.sh`](scripts/homer-known-good.sh) | Explicit recovery-point curation and rejected-artifact handling |
| [`homer-rollback.sh`](scripts/homer-rollback.sh) | KNOWN_GOOD-only recovery with preview and byte-level validation |
| [`homer-user-provision.sh`](scripts/homer-user-provision.sh) | Multi-plane orchestration, idempotent resume, interrupt/partial-state handling |
| [`homer-menu.sh`](scripts/homer-menu.sh) | Operator UX and visible separation of read-only vs privileged workflows |

The public script set is deliberately curated. It demonstrates the engineering decisions without reproducing every private operational utility.

## Repository layout

```text
.
├── README.md
├── docs/
│   ├── ARCHITECTURE.md
│   ├── SAFETY_AND_RECOVERY.md
│   ├── USER_LIFECYCLE.md
│   ├── PUBLIC_SANITIZATION.md
│   └── case-studies/
├── scripts/
└── sql/
```

## Design principles

**Read-only by default.** Reporting and diagnostics should not require elevated privileges unless the underlying data genuinely requires them.

**Fail closed for sensitive writes.** Privileged lifecycle actions stop when required validation, backup or audit prerequisites are unavailable.

**Verify outcomes, not commands.** Successful process exit is useful, but important workflows verify the resulting state independently.

**Separate orchestration from credential handling.** Guided workflows reuse established child implementations instead of moving passwords through wrappers.

**Never treat silence as health.** Scheduled backup/reporting states expose durable status so an empty rotated log cannot be mistaken for successful execution.

**Recovery is curated.** Rollback targets are explicit known-good artifacts, not arbitrary historical files.

**Operator UX matters.** Terminal menus use consistent sections, status colors and stronger visual treatment for privileged or high-risk operations.

## Public sanitization policy

All material published here is reviewed under a stricter rule than “remove passwords”. The public edition removes or generalizes:

- organization, customer and provider names;
- real site/datacenter names;
- production hostnames and capture-node identifiers;
- production IP addresses, subnets and routing prefixes;
- employee usernames, email domains and account names;
- private repository references;
- production storage paths where they reveal topology;
- operational incident/ticket identifiers;
- credentials, hashes, tokens and secret-bearing configuration.

Generic examples use names such as `Site A`, `SBC-A1`, `Carrier Alpha`, `engineer@example.net`, RFC 5737 documentation networks and generalized filesystem roots.

Full policy: [`docs/PUBLIC_SANITIZATION.md`](docs/PUBLIC_SANITIZATION.md)

## Stack

Homer 7 · heplify-server · PostgreSQL · TimescaleDB · Ubuntu Linux · Bash · Python · SQL · Git

## Scope note

This repository demonstrates production engineering patterns and selected sanitized implementations. It is **not** a turnkey deployment package and intentionally omits production secrets, exact topology, organization-specific configuration and some internal automation.
