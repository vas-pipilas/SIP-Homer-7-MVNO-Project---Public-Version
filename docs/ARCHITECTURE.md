# Sanitized Platform Architecture

This document describes the **engineering architecture demonstrated by the public portfolio edition**. Names, counts, addressing and topology details are intentionally generalized and do not describe the live production environment.

## High-level data flow

```text
+---------------------+       +---------------------+
|   Site-A captures   |       |   Site-B captures   |
|   SIP trace exports |       |   SIP trace exports |
+----------+----------+       +----------+----------+
           |                             |
           +-----------+-----------------+
                       |
                       v
            +----------------------+
            | read-only trace area |
            +----------+-----------+
                       |
                discovery watcher
                       |
                       v
            +----------------------+
            | import isolation     |
            | copy / validate      |
            | decompress if needed |
            +----------+-----------+
                       |
                       v
            +----------------------+
            | PCAP -> HEP3 sender  |
            +----------+-----------+
                       |
                       v
            +----------------------+
            | heplify-server       |
            +----------+-----------+
                       |
                       v
            +----------------------+
            | PostgreSQL +         |
            | TimescaleDB / Homer  |
            +----+------------+----+
                 |            |
                 v            v
          +------------+   +----------------------+
          | Homer GUI  |   | operations layer     |
          +------------+   | analytics / backup   |
                           | health / deployment   |
                           | recovery / lifecycle  |
                           +----------------------+
```

## Capture and ingestion model

The production pattern consumes SIP packet captures exported by multiple voice-platform nodes. Shared source storage is treated as **read-only**.

The ingestion pipeline follows a defensive sequence:

1. discover eligible files;
2. copy each candidate to local temporary storage;
3. validate the copied object before processing;
4. decompress locally when required;
5. parse the PCAP sequentially;
6. recognize candidate SIP packets;
7. construct HEP3 records while preserving packet timestamps and network metadata;
8. send to the local HEP receiver;
9. remove temporary files;
10. persist importer state so already-processed files are not blindly replayed.

The public architecture deliberately omits real filenames, capture identifiers, port mappings and source-directory names.

## Data and analytics layer

Homer provides the core SIP search/correlation interface. The custom operations layer adds reporting that is useful to voice engineers during daily operations and incidents.

Representative capabilities include:

- hourly call statistics;
- Answer Seizure Rate and setup-delay metrics;
- failure-rate analysis;
- historical trend views;
- interconnect/SBC route classification;
- traffic breakdown by direction, site and generic carrier grouping;
- ingestion freshness checks;
- database and WAL health checks.

Route direction is derived from packet/network evidence rather than relying solely on display labels. Provider/routing examples in the public repository use fictional names and prefixes.

## Operator-console layer

The scripts are exposed through an interactive terminal console intended for engineers who may not know every underlying command.

The console design distinguishes:

- read-only monitoring;
- normal administrative actions;
- privileged actions;
- high-risk recovery actions.

Presentation is deliberately part of the safety model: consistent headings, status colors, privilege markers and stronger confirmations make it harder to confuse a report with a state-changing action.

## Backup and restore-verification layer

The database recovery design has several distinct checks:

```text
scheduled online backup
        |
        v
immediate manifest/checksum verification
        |
        v
retain verified backup
        |
        +--------------------+
        |                    |
        v                    v
 daily status report    deep restore verification
                             |
                             v
                  disposable PostgreSQL instance
                             |
                    start + query database
                             |
                             v
                         tear down
```

The important design distinction is that a valid backup file is not automatically considered a proven restore. The deep-verification stage exercises an actual start/query path independently.

## Deployment and recovery layer

Repository source and live operational scripts are treated as separate states.

A guarded deployment flow can:

- compare repository and live versions;
- validate syntax before a write;
- display the proposed diff;
- require explicit operator confirmation;
- back up the current live file;
- deploy the selected Git-backed source;
- record commit/checksum provenance in a ledger.

Recovery is built around curated `KNOWN_GOOD` artifacts rather than arbitrary historical files. Rollback preview validates the target and shows the live-to-target difference before replacement.

Git history is not rewritten simply to make production appear synchronized after a rollback; recovery state and source-of-truth state are intentionally distinguishable.

## User lifecycle model

The platform has more than one user plane. The public portfolio demonstrates a central orchestration model rather than forcing an operator to remember multiple unrelated account procedures.

```text
              central User Management
                       |
          +------------+-------------+
          |                          |
          v                          v
   Homer application            pgAdmin account
       lifecycle                   lifecycle
          |                          |
          +------------+-------------+
                       |
                       v
              guided provisioning
             preflight / verify /
             resume / final status
```

The guided workflow collects non-secret identity information once while leaving password entry inside the existing guarded child implementations. It does not collect the shared database credential used by the database-administration interface.

## Audit and privilege boundaries

Security-sensitive management workflows use dedicated audit logs that record operator/action/target/result metadata without recording plaintext passwords or password hashes.

Important patterns demonstrated by the project include:

- least-privilege database roles for monitoring where practical;
- root/admin requirements only for operations that genuinely need them;
- fail-closed behavior when mandatory audit or safety prerequisites are unavailable;
- pre-write backups for configuration databases before sensitive user-lifecycle changes;
- explicit state verification after changes;
- no automatic destructive rollback after partially completed user provisioning.

## Observability principle

A recurring theme in the project is that **absence of output is not evidence of health**.

For example, a weekly backup log can legitimately be empty after daily rotation even though the most recent weekly backup succeeded. The operations layer therefore includes a lightweight daily status reporter that exposes last-backup age and verification state without triggering another backup.

## What is intentionally omitted

This public architecture does not disclose:

- live organization or provider names;
- real geography/site names;
- exact capture-node inventory;
- production IP addressing or routing prefixes;
- production database/user names where those reveal the access model;
- exact shared-storage endpoints;
- secret-bearing application configuration;
- internal repository/deployment endpoints.

See [`PUBLIC_SANITIZATION.md`](PUBLIC_SANITIZATION.md) for the publication policy.
