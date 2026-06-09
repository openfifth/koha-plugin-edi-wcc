package Koha::Plugin::Com::OpenFifth::EdiWcc;

use Modern::Perl;

use base qw{ Koha::Plugins::Base };

use C4::Context;
use Koha::Database;
use Koha::Logger;
use JSON qw( decode_json encode_json );

our $VERSION = '0.1.2';

our $metadata = {
    name            => 'EDI Service Charges (WCC)',
    author          => 'Open Fifth',
    date_authored   => '2026-05-01',
    date_updated    => '2026-06-09',
    minimum_version => '24.11.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Processes MOA+8 service charges (ALC+C) from received EDIFACT INVOIC messages '
        . 'and creates matching invoice adjustments. Runs after the standard edi_cron.pl. '
        . 'Originated as WCC customer-specific work; intended for upstreaming once a core '
        . 'after_edi_cron hook lands.',
};

sub new {
    my ( $class, $args ) = @_;

    $args->{metadata} = $metadata;
    $args->{metadata}->{class} = $class;

    my $self = $class->SUPER::new($args);
    $self->{cgi} = CGI->new();

    return $self;
}

sub install   { return 1; }
sub uninstall { return 1; }
sub upgrade   { return 1; }

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{cgi};

    if ( $cgi->param('save') ) {
        my @vendor_prefixes = $cgi->multi_param('vendor_prefix');
        my @budget_ids      = $cgi->multi_param('budget_id');

        my @mappings;
        for my $i ( 0 .. $#vendor_prefixes ) {
            my $prefix    = $vendor_prefixes[$i] // '';
            my $budget_id = $budget_ids[$i]      // '';
            $prefix    =~ s/^\s+|\s+$//g;
            $budget_id =~ s/^\s+|\s+$//g;
            next unless length($prefix) && $budget_id =~ /^\d+$/;
            push @mappings, { vendor_prefix => $prefix, budget_id => $budget_id + 0 };
        }

        $self->store_data(
            {
                dry_run           => $cgi->param('dry_run') ? 1 : 0,
                verbose           => $cgi->param('verbose') ? 1 : 0,
                vendor_budget_map => encode_json( \@mappings ),
            }
        );
        $self->go_home;
        return;
    }

    my $schema = Koha::Database->new->schema;
    my @budget_list = map {
        { id => $_->budget_id, name => $_->budget_name, code => $_->budget_code // '' }
    } $schema->resultset('Aqbudget')->search( {}, { order_by => 'budget_name' } )->all;

    my $map_json = $self->retrieve_data('vendor_budget_map') // '[]';
    my $mappings = eval { decode_json($map_json) } // [];

    my $template = $self->get_template( { file => 'configure.tt' } );
    $template->param(
        dry_run     => $self->retrieve_data('dry_run') // 1,
        verbose     => $self->retrieve_data('verbose') // 0,
        budget_list => \@budget_list,
        mappings    => $mappings,
    );
    $self->output_html( $template->output );
}

=head2 after_edi_cron

Fires from C<misc/cronjobs/edi_cron.pl> via C<< Koha::Plugins->call >>
once all downloaded EDIFACT messages (quotes, invoices, order responses)
have been processed. Receives the EdifactMessage ids touched in the
current run as C<< $args->{payload}{invoice_ids} >> etc.

This is the only automatic integration point. C<cronjob_nightly> was
deliberately removed — the service charge processor is not idempotent
(re-running would double the adjustments) and tying it to two cron paths
risks exactly that.

Configuration values C<dry_run> and C<verbose> stored via C<configure>
are honoured. C<dry_run> defaults to 1 (safe).

=cut

sub after_edi_cron {
    my ( $self, $args ) = @_;
    return $self->_run_service_charge_processor;
}

sub _run_service_charge_processor {
    my ($self) = @_;

    my $logger = Koha::Logger->get(
        { category => 'Koha.Plugin.Com.OpenFifth.EdiWcc' }
    );

    my $dry_run    = $self->retrieve_data('dry_run') // 1;
    my $verbose    = $self->retrieve_data('verbose') // 0;
    my $map_json   = $self->retrieve_data('vendor_budget_map') // '[]';
    my $budget_map = eval { decode_json($map_json) } // [];

    require Koha::Plugin::Com::OpenFifth::EdiWcc::Processor;

    my $processor = Koha::Plugin::Com::OpenFifth::EdiWcc::Processor->new(
        dry_run    => $dry_run,
        budget_map => $budget_map,
        on_message => sub {
            my ( $text, $is_verbose ) = @_;
            return if $is_verbose && !$verbose;
            $logger->info("EdiWcc: $text");
        },
    );

    my $result = $processor->run;

    $logger->info( sprintf(
        'EdiWcc: processed %d messages, created %d adjustments%s',
        $result->{processed},
        $result->{adjustments},
        $dry_run ? ' (dry run)' : ''
    ));

    return 1;
}

1;
