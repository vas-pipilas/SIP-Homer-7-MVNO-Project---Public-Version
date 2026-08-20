# Public Sanitization Policy

This repository is a **portfolio edition**, not a synchronized copy of the production repository.

The objective is to preserve the engineering substance while preventing the public codebase from revealing organization-specific infrastructure, commercial relationships, identities or credentials.

## Publication rule

A production detail is published only when it is necessary to understand the engineering pattern and can be safely generalized.

When in doubt, the public version removes or replaces the detail.

## Always remove or generalize

The public repository must not contain:

- company, customer, partner or carrier names from the live environment;
- real site, datacenter or office names;
- production hostnames, VM names, capture-node names or inventory identifiers;
- real IP addresses, subnets, routing prefixes or interconnect addressing;
- employee/operator usernames;
- corporate email addresses or private domains;
- passwords, password hashes, API keys, tokens, cookies, SSH secrets or encryption keys;
- secret-bearing PostgreSQL, pgAdmin, Homer, heplify or monitoring configuration;
- private Git repository URLs or deployment credentials;
- production NFS/server endpoints;
- incident, ticket, customer or circuit identifiers;
- logs copied from production when they contain identifying metadata;
- backup paths or filenames when those encode internal topology or organization names.

## Generic naming convention

Use consistent documentation-only replacements:

| Production concept | Public form |
|---|---|
| Physical/virtual location | `Site-A`, `Site-B` |
| SBC | `SBC-A1`, `SBC-B1` |
| Capture node | `CAPTURE-A1`, `CAPTURE-B1` |
| Interconnect/provider | `Carrier-Alpha`, `Carrier-Beta` |
| User | `engineer@example.net` |
| Admin user | `admin@example.net` |
| Database role | `sip_monitor` or another generic least-privilege role |
| Database | `sip_capture` / `app_config` where a generic name is sufficient |
| Addressing | RFC documentation ranges or clearly fictional private ranges |
| Shared storage | `/srv/example/trace-archive` |

Examples must remain internally consistent within each script/document, but do not need to preserve production numbering or topology.

## Code-porting rules

When adapting code from the private project:

1. **Do not copy blindly.** Review the complete source first.
2. Replace organization-specific constants before the public commit is created.
3. Prefer configuration placeholders over hard-coded production-like values.
4. Remove comments that reveal private topology even if the executable code is sanitized.
5. Replace real example output with synthetic output.
6. Avoid publishing production ledger/log extracts.
7. Do not publish historical secrets merely because they are no longer active.
8. Keep password handling demonstrations generic and never include real hashes from production.
9. Use generic role/account names in SQL examples.
10. Run a final repository-wide privacy review before merging the refresh branch into `main`.

## Public architecture rule

The public architecture should communicate:

- data flow;
- component responsibilities;
- failure boundaries;
- privilege boundaries;
- validation and recovery principles;
- operator workflows.

It should **not** provide enough detail to reconstruct the live organization's topology, interconnect relationships, exact capture inventory or access model.

## Public logs and examples

Synthetic examples should use timestamps and identifiers created solely for documentation. Any production-derived output must be rewritten rather than pasted and redacted line-by-line.

This prevents accidental leakage through details that are easy to overlook, such as usernames, host prompts, backup directories, Git commit provenance, provider labels or site names.

## Final review checklist

Before merging a public refresh:

- [ ] no real organization/provider/customer names;
- [ ] no real site names or topology identifiers;
- [ ] no production IPs/subnets/routing prefixes;
- [ ] no employee usernames, corporate domains or email addresses;
- [ ] no secrets/hashes/tokens/private keys;
- [ ] no private repository/remotes;
- [ ] no production logs copied verbatim;
- [ ] no production storage endpoints;
- [ ] examples are explicitly fictional/generic;
- [ ] README accurately states that the repository is sanitized and curated.
