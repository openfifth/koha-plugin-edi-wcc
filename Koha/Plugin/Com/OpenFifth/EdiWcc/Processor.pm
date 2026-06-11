package Koha::Plugin::Com::OpenFifth::EdiWcc::Processor;

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

use C4::Context;
use Koha::Database;
use Koha::Edifact;
use Koha::Logger;

=head1 NAME

Koha::Plugin::Com::OpenFifth::EdiWcc::Processor - EDI service charge processing logic

=head1 SYNOPSIS

    use Koha::Plugin::Com::OpenFifth::EdiWcc::Processor;

    my $processor = Koha::Plugin::Com::OpenFifth::EdiWcc::Processor->new(
        dry_run    => 1,
        budget_map => [ { vendor_prefix => 'WCC', budget_id => 104 }, ... ],
    );

    my $result = $processor->run;
    # $result = { processed => N, adjustments => M, messages => [...] }

=head1 DESCRIPTION

Processes EDI invoice messages that have been received and creates invoice
adjustments for any MOA+8 service charges (ALC+C) found in the EDIFACT data.
Allowances (ALC+A) are skipped.

Since MOA+128/203 totals are inclusive of service charges, this module also
reduces orderline unit prices to avoid double-counting when service charges
are extracted as separate adjustments.

Output is delivered via an C<on_message> callback passed at construction
rather than collected and returned.  This gives callers live feedback as
processing happens rather than a batched dump at the end.

The callback receives C<($text, $is_verbose)> where C<$is_verbose> is 1 for
detail-level messages (show only in verbose/debug mode) and 0 for
summary-level messages that should always be shown.

    on_message => sub {
        my ($text, $is_verbose) = @_;
        print "$text\n" unless $is_verbose && !$my_verbose_flag;
    }

If no C<on_message> is provided the messages are silently discarded; the
structured C<Koha::Logger> entries (written at action-time regardless) still
capture everything.

=cut

sub new {
    my ( $class, %args ) = @_;
    return bless {
        dry_run    => $args{dry_run}    // 1,
        budget_map => $args{budget_map} // [],
        on_message => $args{on_message} // sub {},
        _schema    => Koha::Database->new->schema,
        _logger    => Koha::Logger->get( { interface => 'edi', prefix => 0 } ),
    }, $class;
}

=head2 run

    my $result = $processor->run;

Runs the service charge processor over all received INVOICE messages.
Returns a hashref:

    {
        processed   => $n,   # number of invoice messages processed
        adjustments => $m,   # number of adjustments created (or would create in dry-run)
        messages    => \@msgs,
    }

=cut

sub run {
    my ($self) = @_;

    unless ( C4::Context->preference('EDIFACT') ) {
        $self->{_logger}->warn('EDI Service Charges: EDIFACT syspref is disabled, skipping');
        return { processed => 0, adjustments => 0 };
    }

    $self->_msg(
        $self->{dry_run}
        ? 'Processing EDI service charges (DRY RUN - use --confirm to make actual changes)'
        : 'Processing EDI service charges (LIVE MODE - making database changes)'
    );
    $self->{_logger}->info('EDI Service Charges') unless $self->{dry_run};

    my @invoice_messages = $self->{_schema}->resultset('EdifactMessage')->search(
        { message_type => 'INVOICE', status => 'received' }
    )->all;

    $self->{_logger}->info(
        'EDI Service Charges: Found ' . scalar(@invoice_messages) . ' invoice messages to process'
    );

    my ( $processed_count, $adjustment_count ) = ( 0, 0 );

    for my $invoice_message (@invoice_messages) {
        $self->_msg(
            'Processing message ID: ' . $invoice_message->id . ' (' . $invoice_message->filename . ')',
            1
        );

        my $n = eval { $self->_process_invoice_message($invoice_message) };
        if ($@) {
            $self->{_logger}->error(
                'EDI Service Charges:    Error processing invoice message ' . $invoice_message->id . ": $@"
            );
            $self->_msg( 'ERROR: Failed to process message ' . $invoice_message->id . ": $@" );
            $n = 0;
        }
        $adjustment_count += $n // 0;
        $processed_count++;
    }

    $self->_msg("Processed $processed_count invoice messages");
    $self->_msg("Created $adjustment_count service charge adjustments");
    $self->{_logger}->info(
        "EDI Service Charges: Completed processing. Processed $processed_count messages, created $adjustment_count adjustments"
    );

    return {
        processed   => $processed_count,
        adjustments => $adjustment_count,
    };
}

# ---------------------------------------------------------------------------
# Private methods
# ---------------------------------------------------------------------------

sub _msg {
    my ( $self, $text, $verbose ) = @_;
    $self->{on_message}->( $text, $verbose ? 1 : 0 );
}

sub _process_invoice_message {
    my ( $self, $invoice_message ) = @_;

    my $adjustments_created = 0;

    my $edi      = Koha::Edifact->new( { transmission => $invoice_message->raw_msg } );
    my $messages = $edi->message_array();
    return 0 unless @{$messages};

    for my $msg ( @{$messages} ) {

        # Each message within the transmission has its own BGM invoice number
        my $koha_invoice = $self->_find_koha_invoice_for_message( $invoice_message, $msg );
        unless ($koha_invoice) {
            $self->_msg(
                '  WARNING: Could not find Koha invoice for message within transmission ' . $invoice_message->id
            );
            $self->{_logger}->warn(
                'EDI Service Charges:    Could not find Koha invoice for message within transmission '
                . $invoice_message->id
            );
            next;
        }

        $self->_msg(
            '  Processing message for invoice '
            . $koha_invoice->invoiceid . ' (' . $koha_invoice->invoicenumber . ')',
            1
        );

        # Message-level ALC segments (before first LIN)
        my $message_alcs = $self->_get_message_allowances_charges($msg);
        foreach my $alc_data (@$message_alcs) {
            $adjustments_created += $self->_handle_invoice_level_alc(
                $invoice_message, $koha_invoice, $alc_data
            );
        }

        # Line-level ALC segments
        my $lines            = $msg->lineitems();
        my $orders_processed = {};
        foreach my $line ( @{$lines} ) {
            my $allowances_charges = $self->_get_line_allowances_charges($line);
            next unless @$allowances_charges;

            my $edi_ordernumber    = $line->ordernumber();
            my $received_order     = $self->_find_received_order_for_invoice(
                $edi_ordernumber, $koha_invoice, $orders_processed
            );
            my $actual_ordernumber = $received_order ? $received_order->ordernumber : undef;

            # Accumulate total charges per line for a single orderline price adjustment,
            # avoiding the double-subtract bug when multiple MOA+8 charges exist on one line.
            my $total_charge_excl = 0;
            my $total_charge_tax  = 0;
            my $has_charges       = 0;

            foreach my $alc_data (@$allowances_charges) {
                my ( $created, $charge_excl, $charge_tax ) = $self->_handle_line_level_alc(
                    $invoice_message, $koha_invoice, $line, $alc_data,
                    $received_order, $actual_ordernumber, $edi_ordernumber
                );
                $adjustments_created += $created;
                if ( defined $charge_excl ) {
                    $total_charge_excl += $charge_excl;
                    $total_charge_tax  += $charge_tax;
                    $has_charges = 1;
                }
            }

            # Single orderline price adjustment for all accumulated charges on this line.
            # Calling _adjust_orderline_for_service_charge once per charge would cause each
            # call to subtract only its own amount from the full EDI base price (MOA+128),
            # leaving the last charge's result as the final unit price instead of subtracting all.
            if ( !$self->{dry_run} && $has_charges ) {
                if ($received_order) {
                    $self->_adjust_orderline_for_service_charge(
                        $received_order, $total_charge_excl, $total_charge_tax,
                        $edi_ordernumber, $line
                    );
                } else {
                    $self->{_logger}->warn(
                        'EDI Service Charges: Cannot adjust orderline for service charge - no received order found for line '
                        . $line->line_item_number . " (original order $edi_ordernumber)"
                    );
                }
            } elsif ( $self->{dry_run} && $has_charges ) {
                my $order_info = $actual_ordernumber || $edi_ordernumber || 'Unknown';
                if ( $actual_ordernumber && $actual_ordernumber != $edi_ordernumber ) {
                    $order_info .= " (split from #$edi_ordernumber)";
                }
                $self->_msg(
                    "  Would adjust orderline $order_info to correct price based on EDI PRI data"
                    . " (total charge excl tax: $total_charge_excl, total charge tax: $total_charge_tax)",
                    1
                );
            }
        }
    }

    if ( !$self->{dry_run} ) {
        $invoice_message->status('processed');
        $invoice_message->update;
        $self->_msg( 'Updated invoice message status to processed', 1 );
    } else {
        $self->_msg('Would update invoice message status to processed');
    }

    return $adjustments_created;
}

sub _handle_invoice_level_alc {
    my ( $self, $invoice_message, $koha_invoice, $alc_data ) = @_;

    my $type         = $alc_data->{type};
    my $amount       = $alc_data->{amount};
    my $service_code = $alc_data->{service_code} || 'UNKNOWN';
    my $description  = $alc_data->{description}  || '';

    $self->_msg( "  Found invoice-level $type: $amount ($service_code)", 1 );

    if ( $type eq 'allowance' ) {
        $self->_msg( '  Skipping allowance - not creating adjustment', 1 );
        $self->{_logger}->info(
            'EDI Service Charges: Skipped invoice-level allowance for invoice '
            . $koha_invoice->invoicenumber
            . ": amount=$amount, service_code=$service_code"
        );
        return 0;
    }

    my $vendor_name = $self->_get_vendor_name_from_message($invoice_message);
    my $budget_id   = $self->_map_vendor_to_budget_id($vendor_name);
    $self->_msg( "  Vendor: $vendor_name -> Budget: $budget_id", 1 ) if $vendor_name;

    my $reason   = 'EDI_CHARGE';
    my $existing = $self->{_schema}->resultset('AqinvoiceAdjustment')->search(
        {
            invoiceid  => $koha_invoice->invoiceid,
            reason     => $reason,
            adjustment => $amount,
            note       => { 'LIKE' => '%Invoice-level%' },
        }
    )->first;

    my $adjustment_amount = $self->_calculate_adjustment_amount( $amount, $alc_data->{tax_amount} );

    if ( $adjustment_amount == 0 ) {
        $self->_msg( '  Skipping invoice-level £0 adjustment', 1 );
        $self->{_logger}->info(
            'EDI Service Charges: Skipped invoice-level £0 adjustment for invoice '
            . $koha_invoice->invoicenumber . ": service_code=$service_code"
        );
        return 0;
    }

    if ( !$existing && !$self->{dry_run} ) {
        my $tax_rate_pct = $alc_data->{tax_rate} || 0;
        my $note = sprintf(
            'Invoice-level %s from EDI (ALC+%s, MOA+8) - Service: %s%s | Tax Rate: %s%% | EDI_EXCL: %s | EDI_TAX: %s',
            $type,
            ( $type eq 'charge' ? 'C' : 'A' ),
            $service_code,
            $description ? " ($description)" : '',
            $tax_rate_pct,
            $amount,
            $alc_data->{tax_amount} || 0
        );

        my $adjustment = $self->{_schema}->resultset('AqinvoiceAdjustment')->create(
            {
                invoiceid     => $koha_invoice->invoiceid,
                adjustment    => $adjustment_amount,
                reason        => $reason,
                budget_id     => $budget_id,
                note          => $note,
                encumber_open => 1,
            }
        );

        $self->_msg(
            '  Created invoice-level adjustment ID ' . $adjustment->adjustment_id
            . " for $adjustment_amount"
            . ' (charge: ' . $amount . ', tax: ' . $alc_data->{tax_amount} . ')',
            1
        );
        $self->{_logger}->info(
            'EDI Service Charges:      Created invoice-level adjustment ID '
            . $adjustment->adjustment_id
            . ' for invoice ' . $koha_invoice->invoicenumber
            . ": adjustment=$adjustment_amount (charge=$amount, tax=" . $alc_data->{tax_amount}
            . "), budget_id=$budget_id, service_code=$service_code"
        );
        return 1;
    } elsif ( !$existing ) {
        $self->_msg(
            "  Would create invoice-level $type adjustment: $adjustment_amount"
            . ' (charge: ' . $amount . ', tax: ' . $alc_data->{tax_amount} . ')'
        );
        $self->{_logger}->info(
            'EDI Service Charges: [DRY-RUN] Would create invoice-level adjustment for invoice '
            . $koha_invoice->invoicenumber
            . ": adjustment=$adjustment_amount (charge=$amount, tax=" . $alc_data->{tax_amount}
            . "), budget_id=$budget_id, service_code=$service_code"
        );
        return 1;
    } else {
        $self->{_logger}->info(
            'EDI Service Charges: Skipped duplicate invoice-level adjustment for invoice '
            . $koha_invoice->invoicenumber
            . ": amount=$amount, service_code=$service_code (existing ID "
            . $existing->adjustment_id . ')'
        );
        return 0;
    }
}

sub _handle_line_level_alc {
    my ( $self, $invoice_message, $koha_invoice, $line, $alc_data,
         $received_order, $actual_ordernumber, $edi_ordernumber ) = @_;

    my $type         = $alc_data->{type};
    my $amount       = $alc_data->{amount};
    my $service_code = $alc_data->{service_code} || 'UNKNOWN';
    my $description  = $alc_data->{description}  || '';

    $self->_msg( "  Found $type: $amount ($service_code) for line " . $line->line_item_number, 1 );

    if ( $type eq 'allowance' ) {
        $self->_msg( '  Skipping line-level allowance - not creating adjustment', 1 );
        $self->{_logger}->info(
            'EDI Service Charges: Skipped line-level allowance for line '
            . $line->line_item_number . ' in invoice ' . $koha_invoice->invoicenumber
            . ": amount=$amount, service_code=$service_code"
        );
        return ( 0, undef, undef );
    }

    my $reason              = 'EDI_CHARGE';
    my $existing_adjustment = $self->{_schema}->resultset('AqinvoiceAdjustment')->search(
        {
            invoiceid  => $koha_invoice->invoiceid,
            reason     => $reason,
            adjustment => $amount,
            note       => { 'LIKE' => '%EDI Line: ' . $line->line_item_number . '%' },
        }
    )->first;

    if ($existing_adjustment) {
        $self->_msg( "  $type adjustment already exists for invoice " . $koha_invoice->invoiceid, 1 );
        $self->{_logger}->info(
            'EDI Service Charges: Skipped duplicate line-level adjustment for line '
            . $line->line_item_number . ' in invoice ' . $koha_invoice->invoicenumber
            . ": amount=$amount, service_code=$service_code (existing ID "
            . $existing_adjustment->adjustment_id . ')'
        );
        return ( 0, undef, undef );
    }

    my $vendor_name = $self->_get_vendor_name_from_message($invoice_message);
    my $budget_id   = $self->_map_vendor_to_budget_id($vendor_name);
    $self->_msg( "  Vendor: $vendor_name -> Budget: $budget_id", 1 ) if $vendor_name;

    my $adjustment_amount = $self->_calculate_adjustment_amount( $amount, $alc_data->{tax_amount} );

    if ( $adjustment_amount == 0 ) {
        $self->_msg( '  Skipping line-level £0 adjustment for line ' . $line->line_item_number, 1 );
        $self->{_logger}->info(
            'EDI Service Charges: Skipped line-level £0 adjustment for line '
            . $line->line_item_number . ' in invoice ' . $koha_invoice->invoicenumber
            . ": service_code=$service_code"
        );
        return ( 0, undef, undef );
    }

    my $order_info = $actual_ordernumber || $edi_ordernumber || 'Unknown';
    if ( $actual_ordernumber && $actual_ordernumber != $edi_ordernumber ) {
        $order_info .= " (split from #$edi_ordernumber)";
    }

    if ( !$self->{dry_run} ) {
        my $tax_rate_pct = $alc_data->{tax_rate} || 0;
        my $note = sprintf(
            'EDI %s: Order #%s%s | EDI Line: %s | Service: %s%s | Tax Rate: %s%% | EDI_EXCL: %s | EDI_TAX: %s',
            ucfirst($type),
            $actual_ordernumber || $edi_ordernumber || 'Unknown',
            ( $actual_ordernumber && $actual_ordernumber != $edi_ordernumber )
                ? " (split from #$edi_ordernumber)" : '',
            $line->line_item_number,
            $service_code,
            $description ? " ($description)" : '',
            $tax_rate_pct,
            $amount,
            $alc_data->{tax_amount} || 0
        );

        my $adjustment = $self->{_schema}->resultset('AqinvoiceAdjustment')->create(
            {
                invoiceid     => $koha_invoice->invoiceid,
                adjustment    => $adjustment_amount,
                reason        => $reason,
                budget_id     => $budget_id,
                note          => $note,
                encumber_open => 1,
            }
        );

        $self->_msg(
            '  Created adjustment ID ' . $adjustment->adjustment_id
            . " for $adjustment_amount"
            . ' (charge: ' . $amount . ', tax: ' . $alc_data->{tax_amount} . ')',
            1
        );
        $self->{_logger}->info(
            'EDI Service Charges:      Created line-level adjustment ID '
            . $adjustment->adjustment_id
            . ' for line ' . $line->line_item_number
            . ' in invoice ' . $koha_invoice->invoicenumber
            . ": adjustment=$adjustment_amount (charge=$amount, tax=" . $alc_data->{tax_amount}
            . "), budget_id=$budget_id, service_code=$service_code, order="
            . ( $actual_ordernumber || $edi_ordernumber || 'unknown' )
        );
    } else {
        $self->_msg(
            "  Would create $type adjustment for invoice " . $koha_invoice->invoiceid
            . ": $adjustment_amount (charge: $amount, tax: " . $alc_data->{tax_amount}
            . ") [Budget: $budget_id] [Order: $order_info]"
        );
        $self->{_logger}->info(
            'EDI Service Charges: [DRY-RUN] Would create line-level adjustment for line '
            . $line->line_item_number . ' in invoice ' . $koha_invoice->invoicenumber
            . ": adjustment=$adjustment_amount (charge=$amount, tax=" . $alc_data->{tax_amount}
            . "), budget_id=$budget_id, service_code=$service_code, order=$order_info"
        );
    }

    # Return charge amounts so the caller can accumulate totals for a single
    # orderline price adjustment across all charges on this line.
    return ( 1, $type eq 'charge' ? $amount : undef, $type eq 'charge' ? ( $alc_data->{tax_amount} || 0 ) : undef );
}

sub _get_message_allowances_charges {
    my ( $self, $msg ) = @_;

    my @allowances_charges = ();
    my $current_alc        = undef;

    # Look for ALC segments before the first LIN segment (invoice-level)
    foreach my $seg ( @{ $msg->{datasegs} } ) {
        last if $seg->tag eq 'LIN';

        if ( $seg->tag eq 'ALC' ) {
            push @allowances_charges, $current_alc
                if $current_alc && defined $current_alc->{amount};

            my $qualifier    = $seg->elem(0);
            my $service_code = $seg->elem( 4, 0 ) || '';
            my $service_desc = $seg->elem( 4, 3 ) || '';

            $current_alc = {
                type         => ( $qualifier eq 'C' ) ? 'charge' : 'allowance',
                service_code => $service_code,
                description  => $service_desc,
                amount       => undef,
                tax_amount   => 0,
                tax_rate     => 0,
            };
        } elsif ( $seg->tag eq 'TAX' && $current_alc ) {
            if ( $seg->elem(0) eq '7' ) {
                my $rate = $seg->elem( 4, 3 );
                $current_alc->{tax_rate} = $rate if defined $rate;
            }
        } elsif ( $seg->tag eq 'MOA' && $current_alc ) {
            if ( $seg->elem( 0, 0 ) eq '8' ) {
                $current_alc->{amount} = $seg->elem( 0, 1 );
            } elsif ( $seg->elem( 0, 0 ) eq '124' && defined $current_alc->{amount} ) {
                $current_alc->{tax_amount} = $seg->elem( 0, 1 );
            }
        }
    }

    push @allowances_charges, $current_alc if $current_alc && defined $current_alc->{amount};

    return \@allowances_charges;
}

sub _get_line_allowances_charges {
    my ( $self, $line ) = @_;

    my @allowances_charges = ();
    my $current_alc        = undef;

    foreach my $seg ( @{ $line->{segs} } ) {
        if ( $seg->tag eq 'ALC' ) {
            push @allowances_charges, $current_alc
                if $current_alc && defined $current_alc->{amount};

            my $qualifier    = $seg->elem(0);
            my $service_code = $seg->elem( 4, 0 ) || '';
            my $service_desc = $seg->elem( 4, 3 ) || '';

            $current_alc = {
                type         => ( $qualifier eq 'C' ) ? 'charge' : 'allowance',
                service_code => $service_code,
                description  => $service_desc,
                amount       => undef,
                tax_amount   => 0,
                tax_rate     => 0,
            };
        } elsif ( $seg->tag eq 'TAX' && $current_alc ) {
            if ( $seg->elem(0) eq '7' ) {
                my $rate = $seg->elem( 4, 3 );
                $current_alc->{tax_rate} = $rate if defined $rate;
            }
        } elsif ( $seg->tag eq 'MOA' && $current_alc ) {
            if ( $seg->elem( 0, 0 ) eq '8' ) {
                $current_alc->{amount} = $seg->elem( 0, 1 );
            } elsif ( $seg->elem( 0, 0 ) eq '124' && defined $current_alc->{amount} ) {
                $current_alc->{tax_amount} = $seg->elem( 0, 1 );
            }
        }
    }

    push @allowances_charges, $current_alc if $current_alc && defined $current_alc->{amount};

    return \@allowances_charges;
}

sub _find_koha_invoice_for_message {
    my ( $self, $invoice_message, $msg ) = @_;

    my $bgm_invoice_number = $msg->docmsg_number();
    return unless $bgm_invoice_number;

    my $koha_invoice = $self->{_schema}->resultset('Aqinvoice')->search(
        {
            message_id    => $invoice_message->id,
            invoicenumber => $bgm_invoice_number,
        }
    )->first;

    $self->{_logger}->warn(
        "EDI Service Charges: No Koha invoice found for BGM '$bgm_invoice_number' and message "
        . $invoice_message->id
    ) unless $koha_invoice;

    return $koha_invoice;
}

sub _get_vendor_name_from_message {
    my ( $self, $invoice_message ) = @_;

    return '' unless $invoice_message;

    return $invoice_message->vendor->name
        if $invoice_message->vendor;

    return $invoice_message->edi_acct->vendor->name
        if $invoice_message->edi_acct && $invoice_message->edi_acct->vendor;

    return '';
}

sub _map_vendor_to_budget_id {
    my ( $self, $vendor_name ) = @_;

    return '' unless $vendor_name;

    for my $entry ( @{ $self->{budget_map} } ) {
        my $prefix = $entry->{vendor_prefix} // '';
        next unless length($prefix);
        return $entry->{budget_id} if $vendor_name =~ /^\Q$prefix\E\b/i;
    }

    return '';
}

sub _calculate_adjustment_amount {
    my ( $self, $charge_amount, $tax_amount ) = @_;

    return $charge_amount + $tax_amount
        if C4::Context->preference('CalculateFundValuesIncludingTax');

    return $charge_amount;
}

sub _find_received_order_for_invoice {
    my ( $self, $edi_ordernumber, $koha_invoice, $orders_processed ) = @_;

    return unless $edi_ordernumber && $koha_invoice;

    my @received_orders = $self->{_schema}->resultset('Aqorder')->search(
        {
            invoiceid          => $koha_invoice->invoiceid,
            parent_ordernumber => $edi_ordernumber,
            orderstatus        => 'complete',
        },
        { order_by => { -asc => 'ordernumber' } }
    )->all;

    if ( @received_orders == 1 ) {
        $orders_processed->{ $received_orders[0]->ordernumber } = 1;
        return $received_orders[0];
    }

    for my $actual_order (@received_orders) {
        next if $actual_order->ordernumber == $actual_order->parent_ordernumber;
        next if $orders_processed->{ $actual_order->ordernumber };
        $orders_processed->{ $actual_order->ordernumber } = 1;
        return $actual_order;
    }

    if (@received_orders) {
        $orders_processed->{ $received_orders[0]->ordernumber } = 1;
        return $received_orders[0];
    }

    return;
}

sub _adjust_orderline_for_service_charge {
    my ( $self, $order_to_adjust, $service_charge_amount, $service_charge_tax, $original_ordernumber, $edi_line ) = @_;

    return unless $order_to_adjust;

    my $actual_ordernumber = $order_to_adjust->ordernumber;

    if ( $actual_ordernumber != $original_ordernumber ) {
        my $parent = $order_to_adjust->parent_ordernumber || $original_ordernumber;
        $self->_msg(
            "  Found split order: EDI references $original_ordernumber, adjusting received order $actual_ordernumber (parent: $parent)",
            1
        );
    } else {
        $self->_msg( "  Using original order $original_ordernumber (no split occurred)", 1 );
    }

    my $quantity = $order_to_adjust->quantityreceived || $order_to_adjust->quantity || 1;

    my $line_total = $edi_line->amt_total();
    my $excl_tax   = $edi_line->amt_lineitem();

    unless ( defined $line_total ) {
        my $tax_amount = $edi_line->amt_taxoncharge() || 0;
        $line_total = $excl_tax + $tax_amount;
    }

    my ( $base_unit_price_inc, $base_unit_price_exc );
    if ( $quantity != 1 ) {
        $base_unit_price_inc = $line_total / $quantity;
        $base_unit_price_exc = $excl_tax / $quantity;
    } else {
        $base_unit_price_inc = $line_total;
        $base_unit_price_exc = $excl_tax;
    }

    my $per_unit_service_charge_excl = $service_charge_amount / $quantity;
    my $per_unit_service_charge_tax  = $service_charge_tax / $quantity;
    my $per_unit_service_charge_incl = $per_unit_service_charge_excl + $per_unit_service_charge_tax;

    my $final_unit_price_exc = $base_unit_price_exc - $per_unit_service_charge_excl;
    my $final_unit_price_inc = $base_unit_price_inc - $per_unit_service_charge_incl;

    my $original_line_tax  = $edi_line->amt_taxoncharge() || 0;
    my $adjusted_tax_value = $original_line_tax - $service_charge_tax;

    $order_to_adjust->update(
        {
            unitprice_tax_included => $final_unit_price_inc,
            unitprice_tax_excluded => $final_unit_price_exc,
            tax_value_on_receiving => $adjusted_tax_value,
        }
    );

    my $order_type =
        ( $actual_ordernumber != $original_ordernumber )
        ? "received order $actual_ordernumber (split from $original_ordernumber)"
        : "order $actual_ordernumber";

    $self->_msg(
        "  Set $order_type unit price_inc to $final_unit_price_inc"
        . " (EDI base: $base_unit_price_inc - service charge incl tax: $per_unit_service_charge_incl)",
        1
    );
    $self->_msg(
        "  Set $order_type unit price_exc to $final_unit_price_exc"
        . " (EDI base: $base_unit_price_exc - service charge excl tax: $per_unit_service_charge_excl)",
        1
    );
    $self->_msg(
        "  Set $order_type tax_value to $adjusted_tax_value"
        . " (EDI line tax: $original_line_tax - service charge tax: $service_charge_tax) [TOTAL for all units]",
        1
    );

    $self->{_logger}->info(
        "EDI Service Charges: Processed EDI line with service charge - Order: $order_type, Quantity: $quantity, "
        . "EDI base price_inc: $base_unit_price_inc, EDI base price_exc: $base_unit_price_exc, "
        . "Service charge (excl tax): $per_unit_service_charge_excl, Service charge tax: $per_unit_service_charge_tax, "
        . "Final price_inc: $final_unit_price_inc, Final price_exc: $final_unit_price_exc, "
        . "EDI line tax: $original_line_tax, Adjusted tax_value: $adjusted_tax_value"
    );
}

1;
