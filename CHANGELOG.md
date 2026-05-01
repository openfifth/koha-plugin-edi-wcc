# Changelog

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
