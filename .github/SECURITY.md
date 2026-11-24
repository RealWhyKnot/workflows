# Security policy

These workflows and actions run in other repos' CI.

## Reporting

Please don't open a public issue. Use [a private security advisory](https://github.com/RealWhyKnot/workflows/security/advisories/new) so we can work out a fix before anything is published.

I try to reply within 7 days. There's no bug bounty.

## In scope

- A workflow or action that leaks secrets, runs untrusted input as code, or gets more token permission than it needs.
- A release or tag process that lets someone publish or move a tag they shouldn't.

## Out of scope

- Problems in a repo's own workflow that calls these with unsafe inputs.
- Attacks that need write access to this repo already.
