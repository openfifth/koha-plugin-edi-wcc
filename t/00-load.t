use Modern::Perl;
use Test::More tests => 3;
use Test::Exception;
use JSON::MaybeXS qw(decode_json);
use Path::Tiny qw(path);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
my $package_json_path = path($plugin_dir)->child('package.json');

unshift @INC, $plugin_dir;

my $package_json     = decode_json( $package_json_path->slurp );
my $plugin_module    = $package_json->{plugin}->{module};
my $expected_version = $package_json->{version};

use_ok($plugin_module);

my $plugin;
lives_ok { $plugin = $plugin_module->new() } 'Plugin can be instantiated';

is( $plugin->{metadata}->{version}, $expected_version,
    'Plugin version matches package.json' );
