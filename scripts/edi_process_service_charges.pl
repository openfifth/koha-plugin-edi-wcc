#!/usr/bin/perl

# Copyright 2025 Open Fifth
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;
use utf8;

use FindBin qw($Bin);
use lib "$Bin/..";

use Koha::Script -cron;
use C4::Context;
use JSON qw( decode_json );

use Getopt::Long;
use Pod::Usage;

use Koha::Plugin::Com::OpenFifth::EdiWcc::Processor;

=head1 NAME

edi_process_service_charges.pl - Process MOA+8 service charges (ALC+C) from EDI invoices

=head1 SYNOPSIS

edi_process_service_charges.pl [--confirm|--execute] [--dry-run] [--help] [--verbose]

=head1 DESCRIPTION

This script processes EDI invoice messages that have been received and creates
invoice adjustments for any MOA+8 service charges (ALC+C) found in the EDIFACT data.
Allowances (ALC+A) are skipped as they don't require separate adjustments.

It should be run after edi_cron.pl to capture service charges that are not
handled by the standard EDI processing.

IMPORTANT: Since MOA+128/203 totals are inclusive of service charges, this script
also reduces the orderline unit prices to avoid double-counting when service
charges are extracted as separate adjustments.

All processing logic lives in L<Koha::Plugin::Com::OpenFifth::EdiWcc::Processor>.
This script is a thin CLI wrapper: it parses arguments, constructs a processor
instance, runs it, and prints the results.

=head1 OPTIONS

=over 8

=item B<--dry-run>

Don't actually create invoice adjustments, just show what would be done. This is the default mode.

=item B<--confirm> or B<--execute>

Actually create invoice adjustments. Required to make database changes.

=item B<--budget-map=JSON>

JSON array of vendor-to-budget mappings, e.g. C<[{"vendor_prefix":"WCC","budget_id":104}]>.
When running via the plugin hook this is passed automatically from plugin configuration.
When running manually, omit it (no mappings) or supply it on the command line.

=item B<--verbose>

Provide detailed output of processing.

=item B<--help>

Print this help message.

=back

=cut

my $help            = 0;
my $dry_run         = 1;
my $confirm         = 0;
my $verbose         = 0;
my $budget_map_json = '[]';

GetOptions(
    'help|?'          => \$help,
    'dry-run'         => \$dry_run,
    'confirm|execute' => \$confirm,
    'verbose'         => \$verbose,
    'budget-map=s'    => \$budget_map_json,
) or pod2usage(2);

$dry_run = 0 if $confirm;

pod2usage(1) if $help;

die "Syspref 'EDIFACT' is disabled\n" unless C4::Context->preference('EDIFACT');

my $budget_map = eval { decode_json($budget_map_json) } // [];

my $processor = Koha::Plugin::Com::OpenFifth::EdiWcc::Processor->new(
    dry_run    => $dry_run,
    budget_map => $budget_map,
);

my $result = $processor->run;

for my $msg ( @{ $result->{messages} } ) {
    print $msg->{text} . "\n" if $verbose || !$msg->{verbose};
}

=head1 SETUP INSTRUCTIONS

1. Install the koha-plugin-edi-wcc plugin. It wires this processing up
   automatically via the C<after_edi_cron> hook — no manual cron entry needed.

2. Create the ADJ_REASON authorised values:
   - Go to Administration > Authorised Values
   - Add category ADJ_REASON if it doesn't exist
   - Add value: EDI_CHARGE with description "EDI Charge (ALC+C)"

3. Test with dry-run first (default behavior):
   ./edi_process_service_charges.pl --verbose

4. When ready to make actual changes:
   ./edi_process_service_charges.pl --confirm --verbose

=head1 AUTHOR

Martin Renvoize <martin.renvoize@openfifth.co.uk>

=cut
