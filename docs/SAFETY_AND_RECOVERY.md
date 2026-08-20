# Safety, Deployment and Recovery Design

This public document describes the engineering controls used around operational shell tooling. Production identifiers and exact paths are intentionally generalized.

## Why this layer exists

Operational scripts can be small and still carry real production risk. A one-line change to a health check is low risk; a one-line change to a WAL or account-management script may not be.

The project therefore treats deployment and recovery as explicit workflows rather than as ad-hoc file copying.

## Guarded deployment flow

A typical deployment follows this model:

```text
Git-backed source
      |
      v
compare with live file
      |
      v
syntax / source validation
      |
      v
show unified diff
      |
      v
explicit operator confirmation
      |
      v
backup existing production file
      |
      v
install new version
      |
      v
checksum + provenance ledger
      |
      v
runtime smoke test
```

Important properties:

- the repository remains the reviewed source of truth;
- the operator sees what will change before the write;
- the live artifact is retained before replacement;
- SHA256 and Git commit provenance are recorded;
- production state can be compared against Git without silently rewriting either side.

## Read-only versus privileged operation

The deployment frontend distinguishes information requests from writes.

Read-only status/history operations can be exposed more broadly. Deployment, known-good promotion and rollback remain privileged actions.

This separation is intentional: engineers should be able to understand system state without automatically receiving the ability to change it.

## Curated KNOWN_GOOD restore points

Not every historical version is a safe recovery target.

The recovery model uses explicitly curated artifacts with metadata such as:

- script identity;
- original Git commit;
- artifact checksum;
- promotion time;
- review state.

Artifacts that are rejected are not eligible rollback targets. Superseded history is not automatically treated as safe merely because it once existed.

## Controlled rollback

Rollback is designed as a production recovery action, not a Git-history trick.

A safe rollback workflow can:

1. list eligible curated restore points;
2. validate target metadata and checksum;
3. verify provenance against the original Git artifact where available;
4. show a live-to-target diff;
5. require literal operator confirmation;
6. back up the current live version;
7. replace it with the selected known-good artifact;
8. validate the restored file;
9. append rollback provenance to the deployment ledger;
10. perform a script-specific operational smoke test.

The Git branch is not reset solely because production temporarily returns to an older known-good artifact. That distinction makes the real recovery state visible.

## Recovery exercise philosophy

The project deliberately avoids breaking production merely to prove that rollback exists.

A full A -> B -> A validation should use a naturally occurring safe scenario:

```text
A = retained KNOWN_GOOD
B = later healthy production version

B -> A controlled rollback
verify A
A -> B normal forward deployment
verify B
```

If no genuine B exists, the test remains deferred rather than manufacturing an artificial incident.

## Backup safety

Database backup/recovery uses a separate safety model:

- online base backup;
- immediate manifest/checksum verification;
- previous verified copy retained until the new copy is accepted;
- independent deep restore verification;
- daily status reporting between weekly full runs;
- recovery/WAL operations separated from routine reporting.

The important idea is that **backup creation, backup validation and restore proof are different checks**.

## Sensitive configuration changes

For user-management systems backed by local configuration databases, the workflow creates and verifies a pre-write backup before account state changes.

The scripts then use application-supported lifecycle functions where possible instead of directly modifying encrypted credential material.

## Audit design

Sensitive administrative actions produce security-focused audit records containing non-secret metadata such as:

```text
operator=<generic-user>
action=<operation>
target=<account-or-object>
result=<SUCCESS|FAILED|CANCELLED>
detail=<non-secret-state-transition>
backup=<correlation-path-or-id>
```

Passwords, password hashes, tokens and shared database credentials are intentionally excluded.

## Failure philosophy

The common rules are:

- inspect before changing;
- preserve the previous state before replacing it;
- verify the resulting state independently;
- make partial completion explicit;
- do not automatically destroy a successful earlier step just because a later step failed;
- fail closed when a mandatory safety prerequisite is unavailable.
