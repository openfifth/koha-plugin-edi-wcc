# Changelog

## 0.1.0 — 2026-05-01

Initial extraction from the `24.11.wcc` Koha fork.

- Bundles `scripts/edi_process_service_charges.pl` (processes MOA+8
  service charges from EDIFACT INVOIC into invoice adjustments).
- Bundles `scripts/reset_edi_service_charges.pl` (development helper to
  undo adjustments).
- Implements `cronjob_nightly` so the processor runs via
  `plugins_nightly.pl` without core changes.
- Implements `after_edi_cron` ready for a proposed core hook.
- Configure page exposes `dry_run` and `verbose` defaults.
