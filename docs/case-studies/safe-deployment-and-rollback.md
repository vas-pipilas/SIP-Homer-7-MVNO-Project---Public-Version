# Case Study: Turning Shell Scripts into a Controlled Production Deployment System

## The starting point

The operational toolkit began as a collection of useful shell scripts copied into a live Linux server. That works while the codebase is small, but it creates three uncomfortable questions as the tooling grows:

1. **What exact source version is running in production?**
2. **What changed before the last deployment?**
3. **Can a bad change be reversed without improvising under incident pressure?**

For a telecom operations environment, "the file was copied successfully" is not enough evidence.

## The design goal

The deployment model was deliberately kept human-controlled rather than introducing automatic CI/CD directly into the production server. The goal was not deployment speed; it was **traceability, reviewability and safe recovery**.

The resulting workflow separates Git source from the live runtime directory:

```text
Git source
   |
   | inspect / diff / validate
   v
operator confirmation
   |
   | guarded install
   v
live runtime
   |
   +--> deployment ledger
   +--> pre-change backup
   +--> post-install checksum verification
```

## Guardrail 1: repository state must be understandable

Before a write is allowed, the deployment tool checks that the source tree is on the expected branch and clean. Updates are fast-forward only.

A Git update never modifies production by itself.

That distinction became important operationally: engineers can refresh and inspect source safely without silently changing what is running.

## Guardrail 2: show the real diff

The tool compares each deployable source file with its live counterpart and classifies it as:

- `IDENTICAL`
- `MODIFIED`
- `NEW`

For changed files, a unified diff is shown before deployment. The comparison normalizes only transport noise such as CRLF/LF differences and a missing final newline; it does **not** hide whitespace or content changes that could alter script behavior.

This means the confirmation prompt answers a meaningful question: "Do I want to deploy *these exact changes*?"

## Guardrail 3: validate before touching production

Shell files are syntax-checked with `bash -n`; Python files are compiled before installation.

If source validation fails, production is never opened for modification.

This sounds obvious, but it prevents a surprisingly common failure mode: taking a valid live tool offline by replacing it with a typo that could have been detected before the first write.

## Guardrail 4: preserve the live state before replacement

If the target file already exists, the current live copy is timestamped and backed up before the new source is installed.

The old and new SHA256 values are captured so recovery evidence is based on bytes, not filenames or timestamps.

## Guardrail 5: durable provenance

Every successful deployment appends a ledger record containing the important non-secret provenance:

- deployment timestamp;
- full Git commit;
- deployed filename;
- prior live state;
- old and new SHA256;
- backup artifact path;
- operator identity;
- final result.

The deployment history can therefore answer both directions of the question:

> Which Git commit produced this live file?

and:

> What was running immediately before it?

## The next problem: not every historical version is safe to restore

Keeping backups of old files is useful, but "old" and "known good" are different concepts.

A file can be historically real while also being:

- superseded because it had a bug;
- only briefly deployed;
- never operationally validated;
- explicitly rejected after testing.

So the recovery design introduced **curated KNOWN_GOOD artifacts**.

Promotion is explicit. A restore point records the file checksum and source commit, and its artifact is treated as a recovery candidate only while its state remains `KNOWN_GOOD`.

Rejected artifacts fail closed.

## Controlled rollback

Rollback is not implemented as `git reset`, a forced branch move or an emergency rewrite of repository history.

Instead, the runtime recovery path is:

1. select a curated KNOWN_GOOD artifact;
2. validate its recorded checksum;
3. validate its source provenance where available;
4. preview the live-to-target diff;
5. require literal confirmation;
6. back up the currently running file;
7. restore the curated artifact;
8. syntax-check and checksum the restored result;
9. write rollback provenance to the same deployment ledger.

Git remains the source of truth for normal forward deployment, while production recovery can happen without pretending the older artifact is suddenly the newest Git history.

## A subtle acceptance decision

The rollback mechanism was preview-tested extensively, but the first genuine production-changing A -> B -> A recovery test was deliberately deferred until a naturally safe candidate exists.

At one review point, every curated KNOWN_GOOD artifact was byte-identical to the current live file. Creating a fake "bad" production version solely to prove rollback would have violated the safety principle the recovery system was designed to enforce.

That decision is part of the engineering result: **testability matters, but manufacturing production risk to satisfy a test checkbox is not good validation discipline.**

## What this demonstrates

- building deployment provenance around small operational tools rather than assuming "scripts don't need release engineering";
- separating source refresh from production writes;
- diff-before-deploy and validate-before-write behavior;
- byte-level verification after deployment;
- curated recovery instead of arbitrary historical rollback;
- maintaining Git history integrity during emergency runtime recovery;
- deliberately refusing an unsafe test scenario even when it would make a checklist look complete.
