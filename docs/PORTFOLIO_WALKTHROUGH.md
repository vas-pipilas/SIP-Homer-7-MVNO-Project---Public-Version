# Five-Minute Portfolio Walkthrough

This repository is intentionally larger than a single demo script, but it is not necessary to read everything to understand the engineering approach.

If you are reviewing this as part of a CV or technical interview, this is the shortest useful path through the project.

## Minute 1 — Understand the system

Read the top of [`README.md`](../README.md) and the diagram in [`ARCHITECTURE.md`](ARCHITECTURE.md).

The important idea is that Homer 7 is the SIP visibility foundation, while the custom operations layer adds:

- analytics;
- health/incident tooling;
- verified backup and restore;
- controlled deployment/recovery;
- guided lifecycle automation.

## Minute 2 — Look at one troubleshooting story

Read [`case-studies/asr-investigation.md`](case-studies/asr-investigation.md).

This shows the diagnostic style used throughout the project: test hypotheses against correlated data, distinguish architecture facts from assumptions, and validate the exact production query before changing behavior.

Then look briefly at [`../scripts/homer-callstats.sh`](../scripts/homer-callstats.sh) to see how the resulting metric logic makes excluded traffic visible rather than silently changing a denominator.

## Minute 3 — Look at backup verification

Read [`case-studies/backup-verification.md`](case-studies/backup-verification.md), then scan:

- [`../scripts/homer-db-backup.sh`](../scripts/homer-db-backup.sh)
- [`../scripts/homer-db-backup-deep-verify.sh`](../scripts/homer-db-backup-deep-verify.sh)
- [`../scripts/homer-db-backup-status.sh`](../scripts/homer-db-backup-status.sh)

The core principle is **verify outcomes, not commands**. A physical backup is immediately checked, later restored into a disposable PostgreSQL instance, and then monitored daily for staleness and verification state.

## Minute 4 — Look at deployment and recovery safety

Read [`case-studies/safe-deployment-and-rollback.md`](case-studies/safe-deployment-and-rollback.md), then scan:

- [`../scripts/homer-deploy.sh`](../scripts/homer-deploy.sh)
- [`../scripts/homer-known-good.sh`](../scripts/homer-known-good.sh)
- [`../scripts/homer-rollback.sh`](../scripts/homer-rollback.sh)

The noteworthy part is not that Bash can copy a file. It is the safety model around that copy: clean source state, diff, syntax validation, explicit confirmation, pre-change backup, SHA256 verification and durable provenance.

Rollback targets are curated rather than inferred from "old files".

## Minute 5 — Look at recoverable workflow design

Read [`case-studies/guided-user-provisioning.md`](case-studies/guided-user-provisioning.md) and scan [`../scripts/homer-user-provision.sh`](../scripts/homer-user-provision.sh).

The workflow demonstrates:

- non-secret identity collection once;
- delegation of passwords to child systems;
- preflight and postcondition verification;
- safe resume after partial completion;
- explicit interrupt handling;
- no destructive cross-system auto-rollback.

Finally, open [`../scripts/homer-menu.sh`](../scripts/homer-menu.sh) to see how the individual tools are presented as one operator-facing console with visible risk separation.

## Interview discussion prompts

Useful technical discussion areas include:

- why TCP delivery to a collector is not the same as proving database persistence;
- why `pg_verifybackup` and a real restore test answer different questions;
- why PostgreSQL can accept connections while recovery is still running;
- why a historical artifact is not automatically a safe rollback target;
- why orchestration should not become a new credential-handling layer;
- why a percentage KPI can be wrong even when every individual SIP leg is correctly captured;
- why deliberate non-automation can sometimes reduce production blast radius.

## Publication note

The examples are generalized. Provider names, topology, identities, network addressing, routing values and environment-specific paths are intentionally fictionalized or removed. See [`PUBLIC_SANITIZATION.md`](PUBLIC_SANITIZATION.md).
