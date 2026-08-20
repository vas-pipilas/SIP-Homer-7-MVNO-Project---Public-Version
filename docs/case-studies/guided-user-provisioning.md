# Case Study: Turning Multi-System User Creation into a Recoverable Workflow

## The problem

User onboarding initially meant visiting separate administration paths for each interface. One account belonged to the SIP monitoring application, another belonged to a database administration interface, and each system had its own password rules, role model and verification method.

Nothing was individually complicated, but the workflow depended on operator memory:

```text
create account A
remember account B
remember the expected role
remember the expected dashboard/profile
remember which password belongs where
remember the manual follow-up
```

That becomes fragile as the number of interfaces grows.

## The design principle: orchestrate, do not reimplement

The guided workflow was not allowed to become a new place where passwords were handled or database writes were duplicated.

Instead, it acts as an orchestration layer:

1. collect shared **non-secret identity** once;
2. inspect each supported account plane;
3. show an explicit provisioning plan;
4. invoke the existing guarded child workflow for each required account;
5. independently verify the resulting state;
6. report complete or partial success;
7. safely resume later by detecting what already exists.

Passwords remain inside the child tools that already own their hashing, hidden input, backups and confirmation logic.

## Preflight makes the workflow idempotent

Before creating anything, the wizard checks whether each account exists.

An existing account is not blindly skipped. It is verified against the expected canonical state, for example:

- enabled/active;
- expected role;
- expected dashboard/profile rows;
- expected authentication source.

The resulting plan distinguishes:

- `CREATE`
- `ALREADY PRESENT / VERIFY`
- `EXISTS / NEEDS REVIEW`
- `UNAVAILABLE`

That allows the same workflow to be used for first-time provisioning and recovery from a partially completed run.

## Partial completion is treated as a normal state

A tempting design would automatically delete account A if account B fails. That would make the wizard "transactional" on paper, but it would also introduce destructive rollback into two independent identity systems.

The safer design is explicit partial completion:

```text
Application account   VERIFIED CREATED
Admin account          FAILED / NEEDS REVIEW

Result: PARTIAL
Action: fix/review the failed plane, then rerun preflight
```

The next run detects the successfully-created first account and verifies/skips it instead of creating a duplicate.

## Interruption testing exposed a real gap

During acceptance testing, the workflow was interrupted with `Ctrl-C` after the operator had confirmed the provisioning plan.

The first implementation exited immediately, leaving no orchestration-level audit record showing that the run had been interrupted.

No account had actually been created in that particular test, but the behavior revealed an important recovery gap: after an interrupt, the operator cannot safely assume whether a child workflow had already completed.

The fix added `SIGINT`/`SIGTERM` handling that records an `ABORTED` result and prints a deliberately conservative message:

> Partial state may exist. No automatic rollback is attempted. Re-run preflight before retrying.

The signal handler never attempts to infer or delete cross-system state while an operation may have been in flight.

## Post-create verification caught another subtle bug

A later end-to-end test successfully created the application account, but the orchestration layer reported that stage as failed.

Direct database inspection proved the account and expected dashboard rows were present.

The problem was the verifier itself: it compared a concatenated text representation of a PostgreSQL boolean against one specific rendering (`t`). In that query context the boolean could render as `true`, creating a false negative.

The verifier was changed to test the actual state semantically in SQL:

- username/email match;
- `enabled IS TRUE`;
- expected profile/tenant identifier;
- at least one expected dashboard row.

The next resume run correctly detected both account planes as `VERIFIED EXISTING` and made no duplicate writes.

## Audit design

The orchestration log records events such as:

```text
PROVISION_OPEN
PROVISION_IDENTITY
APP_STAGE
ADMIN_STAGE
PROVISION_ABORT
PROVISION_SUMMARY
```

It records targets and non-secret state transitions, but never plaintext passwords, password hashes or shared database credentials.

Each child administration tool retains its own lower-level audit trail, so the orchestration log answers "what happened across the workflow?" while child logs answer "what happened inside this account plane?"

## Acceptance lifecycle

The final acceptance test covered more than the happy path:

1. cancel before writes;
2. interrupt with Ctrl-C;
3. verify that no partial state existed after that interruption;
4. create both temporary accounts;
5. discover and fix a false-negative post-create verifier;
6. rerun and verify safe existing-account detection;
7. delete both temporary accounts through their normal guarded lifecycle paths;
8. verify all account/configuration rows were gone while audit evidence remained.

That produced a full lifecycle test:

```text
create -> verify -> interrupt -> recover/resume -> verify existing -> delete -> verify cleanup
```

## What this demonstrates

- orchestration without centralizing credentials;
- idempotent workflow design across independent systems;
- safe handling of partial completion;
- explicit interruption recovery instead of optimistic assumptions;
- postcondition verification rather than trusting child exit codes alone;
- learning from acceptance-test edge cases and improving the workflow before declaring it complete;
- operator UX as part of reliability, not just cosmetic formatting.
