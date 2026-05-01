# koha-plugin-edi-wcc

EDI service charges processor for Koha — extracts MOA+8 service charges
(ALC+C) from received EDIFACT INVOIC messages and creates matching
invoice adjustments. Originally developed as customer-specific work for
WCC; packaged as a plugin so it can ship independently of Koha core.

## What it does

Standard Koha EDI invoice handling reconciles MOA+128/203 totals against
orderlines but does not split out service charges (ALC+C) into invoice
adjustments. Supplier invoice totals are *inclusive* of those charges,
which means orderlines end up over-priced if the service charge is not
extracted.

This plugin:

- scans received but un-reconciled EDIFACT INVOIC messages,
- pulls out MOA+8 amounts qualified as ALC+C,
- creates invoice adjustments tagged with the service-charge detail, and
- adjusts orderline unit prices and `tax_value_on_receiving` so the
  invoice total reconciles correctly without double-counting.

ALC+A allowances are intentionally skipped — they don't need separate
adjustments.

## Installation

1. Build a `.kpz` (`npm run release:patch`) or download a release artifact.
2. Upload via *Administration → Manage plugins* in Koha.
3. Open the plugin's *Configure* page and choose dry-run / verbose defaults.

## Running

The plugin runs automatically via the `after_edi_cron` hook fired from
`misc/cronjobs/edi_cron.pl`. No separate cron entry is needed — once the
plugin is installed and configured (dry-run unchecked when ready), every
run of `edi_cron.pl` triggers service-charge processing on the same set
of invoice messages it just imported.

The `after_edi_cron` hook ships in the OpenFifth `25.11.o5th` branch as
a LOCAL commit. It is also a candidate for upstreaming so the plugin can
work on stock community Koha — see *Upstream work* below.

### Manual / one-off runs

The bundled `scripts/edi_process_service_charges.pl` can still be run by
hand for backfills or debugging:

```sh
/var/lib/koha/<instance>/plugins/koha-plugin-edi-wcc/scripts/edi_process_service_charges.pl --dry-run --verbose
```

**Do not put this script in crontab alongside `edi_cron.pl`.** The
processor is not idempotent — running it twice on the same invoice
double-counts the service charge adjustment. The `after_edi_cron` hook is
the only automatic integration point.

## Upstream work

The processing logic itself is WCC-business-specific (vendor-to-budget
mapping, split-order handling, particular tax/allowance behaviour) and
should remain a plugin until those abstractions are generalised. The
plugin's *core integration point* is genuinely general:

- **`after_edi_cron` plugin hook** — adds a single
  `Koha::Plugins->call('after_edi_cron', { action => 'edi_cron_completed', payload => { quote_ids, invoice_ids, response_ids } })`
  call at the end of `misc/cronjobs/edi_cron.pl`. Already on
  `openfifth/25.11.o5th`; should be filed as a community Bugzilla once
  this plugin has been validated in production. Generally useful for
  any post-EDI workflow (SAP exports, finance reconciliation, alerting).
- **Optional: `after_edi_invoice_processed` per-invoice hook** — fired
  from `Koha::EDI::process_invoice` once an invoice has been created.
  Better granularity but larger surface; secondary, and only worth
  pursuing if a use case other than this plugin emerges.

## Maintenance

The bundled `scripts/reset_edi_service_charges.pl` undoes adjustments
created by this plugin (development/test use; not for production).

## Versioning

```
npm run version:patch     # bump 0.1.0 → 0.1.1
npm run version:minor     # bump 0.1.0 → 0.2.0
npm run release:patch     # bump + tag + push
```

`increment_version.js` keeps the plugin `$VERSION` and `date_updated`
in sync with `package.json`.

## Origin

Extracted from the WCC customer fork of Koha (`24.11.wcc`). Source
commits squashed into this plugin:

- Initial script + vendor-to-budget mapping
- Allowance-sign / split-order / multi-message fixes
- Tax handling (TAX segment, `tax_value_on_receiving` recalculation)
- £0 adjustment guard, missing-order handling, LSL field copy fixes
