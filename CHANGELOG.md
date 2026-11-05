# Changelog

## [Unreleased]

### Fixed

- Rebuild the CI workflow on the template's KTD setup (still testing against the o5th Koha fork): the old workflow downloaded `docker-compose.yml` from a koha-testing-docker GitLab URL that now returns 404, failing the 0.1.7 release run.

## [0.1.7] - 2026-11-05

### Changed

- Adopt the plugin template's CI and release tooling: `npm run release:*` scripts and preflight, `DEVELOPMENT.md`, a `t/00-load.t` smoke test and the GitHub Actions workflow (already current/customised, left as is).

- Relicensed under AGPL-3.0-or-later: added `LICENSE`, SPDX header, and `license`/`license_url` plugin metadata.

## 0.1.0 — 2026-05-01

Initial extraction from the `24.11.wcc` Koha fork.

- Bundles `scripts/edi_process_service_charges.pl` (processes MOA+8
  service charges from EDIFACT INVOIC into invoice adjustments).
- Bundles `scripts/reset_edi_service_charges.pl` (development helper to
  undo adjustments).
- Wires the `after_edi_cron` hook (added as a LOCAL commit on
  `openfifth/25.11.o5th`) as the sole automatic integration point.
  `cronjob_nightly` was deliberately not implemented — the processor
  is not idempotent and a second cron path would double-count
  adjustments.
- Configure page exposes `dry_run` and `verbose` defaults.

[Unreleased]: https://github.com/openfifth/koha-plugin-edi-wcc/compare/v0.1.7...HEAD
[0.1.7]: https://github.com/openfifth/koha-plugin-edi-wcc/compare/v0.1.6...v0.1.7