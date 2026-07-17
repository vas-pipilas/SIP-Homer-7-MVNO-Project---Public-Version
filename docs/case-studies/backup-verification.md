# Case Study: Proving a Backup Actually Restores, Not Just Exists

## The problem

The platform's original backup strategy kept two full database backups plus
roughly two weeks of Write-Ahead Log (WAL) retention, as a safety margin
against one backup turning out silently bad. On a database in the
low-hundreds-of-gigabytes range, this pushed total backup storage toward
roughly a terabyte — flagged by infrastructure as more than reasonable for
what it actually protected against.

The fix looked simple on paper: keep one backup, retain only the WAL
generated since it, verify integrity properly to compensate for the removed
safety margin. In practice, actually proving a backup *restores* — not just
that its checksums match — surfaced four separate, genuinely non-obvious
PostgreSQL and Linux-distribution quirks, each one only discoverable by
actually trying to restore for real.

## The design

Two layers of verification, deliberately separated:

1. **Immediate, cheap**: `pg_verifybackup` runs right after every backup
   completes, checking the backup's files against its own manifest
   checksums. The previous backup is never deleted until this passes — so
   even with only one backup kept, there's never a moment with zero valid
   backups on disk.

2. **Deep, expensive, asynchronous**: a separate script copies the current
   backup to a scratch location, spins up a completely disposable
   PostgreSQL instance from it on an alternate port, replays the WAL forward,
   confirms the instance actually reaches a consistent state and answers a
   real query, then tears everything down and deletes the scratch copy
   entirely. This runs on its own schedule (roughly a day after the backup
   itself, since a full restore-and-replay test on a large database
   legitimately takes hours) — genuinely proving the backup restores, not
   just that its bytes look intact.

A small state file ties the two together: a fresh backup resets verification
status to "pending" under a new ID, and the deep-verify script updates it to
pass/fail once it completes. A separate monitoring script alarms if
verification ever fails, or if it's been pending suspiciously long (meaning
the deep-verify job itself might not be running). Taking a new manual backup
naturally clears any old failure alarm — the alarm is tied to a specific
backup's identity, not a standing flag, so there's no separate "acknowledge"
step to remember.

## Four real bugs, in the order they were found

**1. Two PostgreSQL tools weren't on the system `PATH` at all.**
Most Postgres client tools get symlinked onto `PATH` by this distribution's
packaging — but two administrative tools (`pg_ctl`, `pg_verifybackup`)
deliberately are not, and only exist at a versioned install path. The first
real attempt wasted a full multi-hour backup transfer, then failed
`pg_verifybackup` with a plain "command not found" — which the script
initially (and wrongly) treated identically to "the backup is corrupt,"
discarding a perfectly good backup as a result.

Fixed with a small resolver that tries `PATH` first, falls back to known
install locations, and — critically — checks *before* the expensive
operation runs, so a missing-tool problem now fails in seconds instead of
after hours of wasted I/O. "Tool not found" and "verification genuinely
failed" are now always reported as distinct outcomes.

**2. The distribution keeps core config files outside the data directory.**
A standard PostgreSQL install keeps `postgresql.conf` and `pg_hba.conf`
inside the data directory, so a physical backup naturally includes them.
This distribution's packaging deliberately keeps them elsewhere — meaning a
restored backup copy has *no config files at all*, not because anything
broke, but because they were never part of the data directory to begin with.

The fix does **not** copy the live server's actual config file into the
scratch restore — that file typically contains absolute paths pointing back
at the real, live cluster (its actual data directory, its actual PID file
location), and reusing it verbatim on a disposable test instance risked that
instance quietly referencing pieces of the real, live system. Instead, the
script writes a clean, minimal, fully self-contained config that only ever
points at its own scratch directory.

**3. PostgreSQL enforces a monotonic floor on certain settings during
recovery.** Several parameters (`max_connections`, `max_worker_processes`,
and a few others tied to shared-memory-tracked slots) must be at least as
large during recovery as they were on the original server when the WAL
being replayed was generated — otherwise PostgreSQL refuses to proceed,
rather than risk running out of tracking slots mid-replay. The scratch
instance's defaults were lower than the live server's tuned values,
producing an "insufficient parameter settings" failure. Fixed by querying
the live server's actual current settings and matching them exactly on the
scratch instance, rather than guessing generously-high numbers.

**4. "Accepting connections" isn't the same as "replay has finished."**
Once the scratch instance was actually starting, the readiness check simply
polled for the port to accept a connection. PostgreSQL can accept read-only
connections *while still actively replaying WAL* — a completely standard
"hot standby" behavior. The very first real validation query happened to
land in that in-between window and was cancelled by the server with
"conflict with recovery," since active replay needed to reclaim a row
version the query was reading. Not corruption — a normal timing race.

Fixed by polling `pg_is_in_recovery()` instead of just the port — waiting
specifically until the instance reports it has fully caught up and promoted
out of recovery mode, before ever running the real validation query against
it.

## Outcome

Confirmed, full end-to-end pass on the first attempt after all four fixes:
a multi-hundred-gigabyte backup copied, a disposable instance started,
recovery completed and the instance promoted, a real query returned real,
current data, and the scratch environment torn down completely with nothing
left behind. This is now a scheduled, unattended, weekly-proven restore
path — not a script that merely runs without erroring.

## What this shows

- Treating "the command exited zero" and "the thing actually works" as
  different claims requiring different evidence
- Each of these four issues was a genuine platform/packaging quirk, not
  careless scripting — the kind of thing only surfaces by actually
  attempting the real operation, not by reasoning about it in the abstract
- Deliberately not taking a shortcut (like reusing the live server's real
  config file) even when it would have "worked" for the happy path, because
  it carried a real risk of the test instance touching the live system
- Building in defensive checks (fail fast on a missing tool, detect a dead
  process mid-poll) discovered to be necessary only after hitting the
  failure mode they now guard against
