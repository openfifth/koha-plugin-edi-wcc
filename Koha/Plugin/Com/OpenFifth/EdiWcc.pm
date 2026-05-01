package Koha::Plugin::Com::OpenFifth::EdiWcc;

use Modern::Perl;

use base qw{ Koha::Plugins::Base };

use C4::Context;
use Koha::Logger;

use File::Spec;
use Cwd qw( abs_path );

our $VERSION = '0.1.0';

our $metadata = {
    name            => 'EDI Service Charges (WCC)',
    author          => 'Open Fifth',
    date_authored   => '2026-05-01',
    date_updated    => '2026-05-01',
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
        $self->store_data(
            {
                dry_run => $cgi->param('dry_run') ? 1 : 0,
                verbose => $cgi->param('verbose') ? 1 : 0,
            }
        );
        $self->go_home;
        return;
    }

    my $template = $self->get_template( { file => 'configure.tt' } );
    $template->param(
        dry_run => $self->retrieve_data('dry_run') // 1,
        verbose => $self->retrieve_data('verbose') // 0,
    );
    $self->output_html( $template->output );
}

=head2 cronjob_nightly

Plugin hook invoked by C<plugins_nightly.pl>. Runs the bundled
C<edi_process_service_charges.pl> script. This is a temporary integration
point until a dedicated C<after_edi_cron> core hook is added.

Configuration values C<dry_run> and C<verbose> stored via C<configure> are
honoured. C<dry_run> defaults to 1 (safe).

=cut

sub cronjob_nightly {
    my ($self) = @_;
    return $self->_run_service_charge_processor;
}

=head2 after_edi_cron

Proposed Koha core hook. Once C<misc/cronjobs/edi_cron.pl> calls
C<< Koha::Plugins->new->call('after_edi_cron', \%args) >> at the end of its
processing loop, this method will fire automatically and replace
C<cronjob_nightly> as the primary integration point.

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

    my $dry_run = $self->retrieve_data('dry_run') // 1;
    my $verbose = $self->retrieve_data('verbose') // 0;

    my $script = $self->_script_path('edi_process_service_charges.pl');
    unless ( -e $script ) {
        $logger->error("EdiWcc: bundled script not found at $script");
        return;
    }

    my @cmd = ( $^X, $script );
    push @cmd, $dry_run ? '--dry-run' : '--confirm';
    push @cmd, '--verbose' if $verbose;

    $logger->info( 'EdiWcc: running ' . join ' ', @cmd );
    my $rc = system(@cmd);
    if ($rc != 0) {
        $logger->error("EdiWcc: service charge processor exited with status $rc");
    }
    return $rc == 0;
}

sub _script_path {
    my ( $self, $name ) = @_;
    my $module = __FILE__;
    my $dir    = ( File::Spec->splitpath($module) )[1];
    return abs_path( File::Spec->catfile( $dir, '..', '..', '..', '..', '..', 'scripts', $name ) );
}

1;
