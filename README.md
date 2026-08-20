# SIP Homer 7 — Production Voice Operations Toolkit

A sanitized portfolio edition of tooling built around **Homer 7**, PostgreSQL and Linux for production SIP/VoIP operations.

This repository is intentionally **not a production mirror**. It demonstrates the engineering patterns, safety controls, automation and troubleshooting workflows developed for a real multi-site voice platform while replacing or removing organization-specific topology, addressing, provider names, usernames, domains, credentials and operational identifiers.

> **Portfolio goal:** show how an open-source SIP capture platform can be extended into an operator-facing production toolkit with observability, recovery, deployment safety and guided lifecycle automation.

## What this project demonstrates

The project evolved well beyond a set of monitoring scripts. The operational layer now covers:

- SIP KPI and call-quality analytics
- interconnect/SBC route classification and historical reporting
- automated PCAP ingestion and HEP delivery patterns
- full PostgreSQL backups with immediate verification
- real restore/deep-verification testing in disposable database instances
- daily backup-health reporting so silence is never mistaken for success
- emergency and deep platform health checks
- guarded configuration backup/recovery workflows
- Git-to-production deployment controls with provenance and checksums
- curated `KNOWN_GOOD` recovery points and controlled rollback design
- privilege-aware operator consoles
- Homer and pgAdmin user lifecycle management
- guided multi-interface user provisioning with safe resume behavior
- security-sensitive audit logging without credential leakage
- consistent terminal UX for normal, privileged and high-risk actions

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

The backup design does not stop at “the file exists”. It combines:

1. online PostgreSQL base backup;
2. immediate manifest/checksum verification;
3. retention safety so a previous good copy is not discarded prematurely;
4. a separate deep verification workflow that restores the backup into a disposable PostgreSQL instance, starts it and proves it is queryable;
5. a lightweight daily status reporter that exposes backup age and deep-verification state between weekly backup runs.

Case study: [`docs/case-studies/backup-verification.md`](docs/case-studies/backup-verification.md)

### 2. SIP KPI investigation instead of assumption-driven fixes

The call-statistics layer calculates operational metrics such as ASR, PDD, call setup time and failure rates across capture tiers. One production investigation followed multiple competing hypotheses before isolating the actual reason for a persistent metric discrepancy.

Case study: [`docs/case-studies/asr-investigation.md`](docs/case-studies/asr-investigation.md)

### 3. Safe Git-to-production operations

The newer operational model adds deployment provenance and recovery controls around shell tooling:

- compare repository source against the live production copy;
- syntax validation before deployment;
- operator confirmation for writes;
- timestamped production backup before replacement;
- deployment ledger entries with Git commit and SHA256 provenance;
- curated `KNOWN_GOOD` restore points;
- controlled rollback preview with checksum/provenance validation;
- no rewriting of Git history just to make a rollback look clean.

This is summarized in [`docs/SAFETY_AND_RECOVERY.md`](docs/SAFETY_AND_RECOVERY.md).

### 4. Guided user lifecycle across multiple interfaces

The project now treats user onboarding as an operational workflow rather than a collection of unrelated scripts. A central wizard can preflight multiple user planes, explain the plan, invoke the existing guarded child workflows, verify each result and safely resume after partial completion or interruption.

The orchestration layer never collects shared database credentials and does not duplicate password-handling logic owned by the underlying tools.

See [`docs/USER_LIFECYCLE.md`](docs/USER_LIFECYCLE.md).

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

The public script set is deliberately curated. It is intended to demonstrate engineering decisions clearly rather than reproduce every production utility.

## Design principles

**Read-only by default.** Reporting and diagnostics should not require elevated privileges unless the underlying data genuinely requires them.

**Fail closed for sensitive writes.** Privileged lifecycle actions should stop if required backups, validation or audit sinks are unavailable.

**Verify outcomes, not commands.** Successful process exit is useful, but important workflows verify the resulting state independently.

**Separate orchestration from credential handling.** Guided workflows reuse established child implementations instead of moving passwords through wrapper scripts.

**Never treat silence as health.** Scheduled backup/reporting states expose durable status so an empty rotated log cannot be mistaken for successful execution.

**Recovery is curated.** Rollback targets are explicit known-good artifacts, not arbitrary historical files.

**Operator UX matters.** Terminal menus use consistent sections, status colors and stronger visual treatment for privileged or high-risk operations.

## Public sanitization policy

All material published here is reviewed under a stricter rule than “remove passwords”. The public edition removes or generalizes:

- organization, customer and provider names;
- real site/datacenter names;
- production hostnames and capture-node identifiers;
- IP addresses, subnets and routing prefixes;
- employee usernames, email domains and account names;
- private repository references;
- production storage paths where they reveal topology;
- operational incident/ticket identifiers;
- credentials, hashes, tokens and secret-bearing configuration.

Generic examples use names such as `Site-A`, `SBC-A1`, `Carrier-Alpha`, `engineer@example.net` and documentation-only RFC/private address ranges.

Full policy: [`docs/PUBLIC_SANITIZATION.md`](docs/PUBLIC_SANITIZATION.md)

## Stack

Homer 7 · heplify-server · PostgreSQL · TimescaleDB · Ubuntu Linux · Bash · Python · SQL · Git

## Scope note

This repository demonstrates production engineering patterns and selected sanitized implementations. It is **not** a turnkey deployment package and intentionally omits production secrets, exact topology, organization-specific configuration and some internal automation.