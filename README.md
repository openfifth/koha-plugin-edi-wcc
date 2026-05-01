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

There are three ways to run the processor; pick whichever fits the
deployment:

### A. From the existing EDI cron sequence (current state)

The plugin ships the original `edi_process_service_charges.pl` under
`scripts/`. Add it to crontab immediately after `edi_cron.pl`:

```cron
*/15 * * * *  /usr/share/koha/bin/cronjobs/edi_cron.pl >> /var/log/koha/edi.log 2>&1
*/15 * * * *  sleep 60 && /var/lib/koha/<instance>/plugins/koha-plugin-edi-wcc/scripts/edi_process_service_charges.pl --confirm >> /var/log/koha/edi.log 2>&1
```

### B. Via `plugins_nightly.pl`

The plugin implements `cronjob_nightly`, so a nightly run will happen
automatically wherever `misc/cronjobs/plugins_nightly.pl` is scheduled.
Use the *Configure* page to set dry-run/verbose defaults. This does *not*
run with `--confirm` unless dry-run is unchecked in configuration.

### C. Via a proposed `after_edi_cron` core hook (planned)

The plugin already implements an `after_edi_cron` method. Once Koha
core's `misc/cronjobs/edi_cron.pl` invokes
`Koha::Plugins->new->call('after_edi_cron', \%args)` at the end of its
processing loop, the plugin will fire automatically with no separate cron
entry needed. The core change is small (a single `call`) and is the
right long-term integration point. See *Upstream work* below.

## Upstream work

The processing logic itself is WCC-business-specific (vendor-to-budget
mapping, split-order handling, particular tax/allowance behaviour) and
should remain a plugin until those abstractions are generalised. However,
to make the plugin model viable, Koha core needs an integration point.
Items to upstream:

1. **`after_edi_cron` plugin hook** — add a single
   `Koha::Plugins->new->call('after_edi_cron', { invoices => \@processed_invoicenumbers })`
   to the end of `misc/cronjobs/edi_cron.pl`. Documented use case: this
   plugin.
2. **Optional: `after_edi_invoice_processed` per-invoice hook** — fired
   from `Koha::EDI::process_invoice` once an invoice has been created.
   Better granularity but larger surface; secondary.

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
