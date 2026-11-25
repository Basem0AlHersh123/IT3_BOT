---
status: accepted
door: two-way
---

# Upstream Relationship with the Original Cohort Bot

This repository is a fork of the original single-cohort bot created by a university peer, evolved into the multi-tenant College Edition. We keep the original repository configured as `upstream` and contribute generic bug fixes and non-college-specific improvements back upstream via issues or pull requests.

## Considered Options

- **Hard fork with zero upstream contact**: loses collaboration benefits and makes future teamwork harder.
- **Merge multi-tenancy upstream immediately**: forces complexity onto single-cohort users who don't need it yet.

## Consequences

- Generic fixes (such as missing dependencies in requirements files or reliability bug fixes) should be kept clean and small so they can be shared upstream.
- Multi-tenant and college-specific features live cleanly on this fork without breaking upstream compatibility unnecessarily.
