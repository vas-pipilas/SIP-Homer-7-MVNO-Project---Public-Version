# Guided Multi-Interface User Lifecycle

This document describes a sanitized version of the user-management architecture added around the Homer platform.

The key problem was simple: one engineer may need accounts in more than one interface. Requiring operators to remember separate menus, templates and credential rules does not scale well and increases onboarding mistakes.

## Central user-management model

```text
                 User Management
                      |
        +-------------+-------------+
        |                           |
        v                           v
 Homer application             pgAdmin-style
 user management               DB admin users
        |                           |
        +-------------+-------------+
                      |
                      v
             Guided Provisioning
```

The central menu keeps individual lifecycle tools available while also exposing one recommended guided onboarding path.

## What the guided workflow does

A typical run follows this pattern:

```text
1. collect non-secret engineer identity
2. preflight every supported user plane
3. show the provisioning plan
4. create or verify the application account
5. create or verify the database-admin GUI account
6. verify the resulting states independently
7. explain any separate manual credential step
8. present a final COMPLETE / PARTIAL summary
```

The design is intentionally extensible: a future third interface can be represented as another stage without redesigning the whole workflow.

## Orchestration, not duplicated implementations

The wizard does **not** reproduce the credential/database logic owned by the individual user-management tools.

Instead:

- shared identity fields are collected once;
- the established child tool performs its own protected password entry;
- each child keeps its own confirmation and backup behavior;
- the orchestration layer verifies the final state after the child returns.

This avoids creating a new code path for password hashing or account writes simply because a nicer workflow was added.

## Application-user template model

New application users can inherit a canonical dashboard/configuration template rather than depending on one employee's personal account as the source template.

The creation workflow validates that the expected template configuration exists before creating the account and verifies that the expected rows were copied afterward.

In the public edition the template identity and database fields are generalized.

## Database-admin GUI account model

The second user plane demonstrates guarded lifecycle operations such as:

- list users;
- change GUI login password;
- activate/deactivate an account;
- change role between normal user and administrator where authorized;
- create a canonical engineer account;
- permanently delete an account through the application's native lifecycle functions.

Sensitive changes require a verified configuration-database backup first.

## Separate shared database credential

An important boundary is that the GUI account password and the shared PostgreSQL connection credential are different things.

The guided provisioning workflow never collects the shared database password. If the newly created GUI user needs to connect to the shared database entry, that credential is entered separately through the approved GUI procedure by an authorized operator.

This keeps the orchestration path from becoming a credential transport mechanism.

## Safe resume and partial completion

The workflow is designed to survive interruption or a failed later stage.

Example:

```text
Application account   CREATED + VERIFIED
DB admin GUI account  CANCELLED

Final result: PARTIAL
```

The wizard does **not** automatically delete the successful application account.

When rerun it preflights both systems:

```text
Application account   ALREADY PRESENT / VERIFY
DB admin GUI account  CREATE
```

That gives the operator a controlled resume path instead of turning a recoverable partial state into a destructive rollback problem.

## Existing-account verification

An existing account is not automatically considered healthy merely because its username exists.

The workflow verifies relevant non-secret state, for example:

- identity matches;
- account is enabled/active;
- expected application template/dashboard configuration exists;
- expected normal-user role is assigned for a canonical engineer profile.

If an existing account does not match the canonical state, the wizard reports it for review instead of silently modifying it.

## Interruption handling

The guided launcher traps interruption signals and records an `ABORTED` orchestration event.

The operator is warned that partial state may exist and is instructed to rerun preflight before retrying. No automatic destructive cleanup is performed.

## Audit model

The orchestration log records events such as:

```text
PROVISION_OPEN
PROVISION_IDENTITY
APPLICATION_STAGE
DB_GUI_STAGE
PROVISION_SUMMARY
PROVISION_ABORT
```

The log contains identities and state outcomes needed for operational audit, but never plaintext passwords, password hashes or the shared database credential.

## Operator UX

The guided workflow uses the same terminal conventions as the wider operator console:

- standard banner;
- visually distinct section headings;
- numbered stage progress;
- `[OK]`, `[INFO]`, `[WARN]`, `[ERROR]` status treatment;
- clear final summary;
- explicit manual follow-up when required.

This is more than cosmetic: consistent UX helps an operator distinguish verification, cancellation and state-changing steps while working under incident or maintenance pressure.
