# SIP Voice Platform: Monitoring, Backup Verification & Incident Tooling

A curated showcase of tooling I built and operate for a production SIP voice
platform at a mobile virtual network operator — real-time call quality
monitoring, SBC route-prefix traffic analysis, a genuinely-verified backup
system, and operator-facing incident tooling, all built on top of
[Homer 7](https://github.com/sipcapture/homer) (open-source SIP capture and
monitoring) and PostgreSQL/TimescaleDB.

This isn't a demo project — it's a curated, generalized extract from
scripts and systems actually running in production, with company names,
carrier names, real IP addressing, and internal identifiers replaced
throughout. The engineering substance — the debugging, the investigations,
the design decisions — is real and unmodified.

## Why this repo exists

Two things I care about most in infrastructure work: **building things that
actually work under real conditions** (not just in the happy path), and
**being rigorous about *why* something is happening** before changing
production. The two case studies below are the best evidence of both.

## Highlights — read these first

- **[Chasing a Phantom 5-Point Metric Gap](docs/case-studies/asr-investigation.md)**
  — a persistent, unexplained call-quality metric discrepancy between two
  tiers of the platform, resolved through six systematically-tested and
  eliminated hypotheses before finding the real cause — including catching
  and reverting a flawed first fix before it reached production.

- **[Proving a Backup Actually Restores, Not Just Exists](docs/case-studies/backup-verification.md)**
  — designing a real restore-verification system (not just checksum
  validation) that spins up a disposable database instance to prove a
  backup genuinely works. Surfaced and fixed four separate, non-obvious
  PostgreSQL/Linux packaging quirks along the way.

## What's in this repo

### `scripts/`

| Script | What it does |
|---|---|
| `homer-db-backup.sh` | Weekly online full backup with immediate checksum/manifest verification before any rotation happens |
| `homer-db-backup-deep-verify.sh` | Real restore test — spins up a disposable PostgreSQL instance from the backup, replays WAL, confirms it's genuinely queryable, tears itself down completely |
| `homer-callstats.sh` | Hourly call-quality statistics (Answer Seizure Rate, Post-Dial Delay, Call Setup Time, network-failure rate) per node, per site, per platform tier |
| `homer-sbc-routes.sh` / `homer-sbc-routes-summary.sh` | Classifies SBC-facing traffic by routing prefix to break down interconnect traffic by carrier and direction, with historical rollups |
| `homer-emergency-healthcheck.sh` | A full-VM health check any engineer can run with zero prior context — checks services, database connectivity, disk/WAL health, ingestion freshness, and explains findings in plain language with an escalation path, never requiring a password prompt |
| `homer-menu.sh` | An interactive operator console wrapping the above, with risk-tiered confirmations for anything that mutates live state |

### `sql/`

A standalone version of the SBC route-prefix analysis query, for ad-hoc use
directly against the database.

### `docs/case-studies/`

The two write-ups linked above.

## Technical characteristics worth noting

- **Direction/classification derived from network addressing, not labels**
  — the route-analysis tooling determines call direction from actual
  `srcIp`/`dstIp`, not from a naming convention that could drift from
  reality
- **Fallback logic for ingestion lag** — reporting scripts automatically
  step back to the most recent hour that actually has data, rather than
  reporting "no data" during normal import lag
- **Privilege-aware, never blocking** — anything requiring elevated access
  checks for it cleanly and reports what's needed instead of hanging on an
  interactive password prompt
- **Credentials never in version control** — all scripts read database
  credentials from a locally-sourced file, never hardcoded

## Stack

Homer 7 · heplify-server · PostgreSQL 16 · TimescaleDB · Loki · Grafana Alloy
· Ubuntu 24.04 · bash · SQL
