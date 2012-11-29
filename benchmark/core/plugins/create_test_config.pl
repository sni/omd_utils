#!/usr/bin/env perl


use warnings;
use strict;
use Getopt::Long;
use Monitoring::Generator::TestConfig;
use POSIX;

#########################################################################
# parse and check cmd line arguments
my ($opt_p, $opt_h, $opt_s);
Getopt::Long::Configure('no_ignore_case');
if(!GetOptions (
   "p=s"            => \$opt_p,
   "s=s"            => \$opt_s,
)) {
    pod2usage( { -verbose => 1, -message => 'error in options' } );
    exit 3;
}

#########################################################################
$opt_p = undef;
my $ngt = Monitoring::Generator::TestConfig->new(
                    'verbose'                   => 1,
                    'overwrite_dir'             => 1,
                    'routercount'               => 10,
                    'fixed_length'              => 6,
                    'hostcount'                 => ceil($opt_s/100),
                    'hostcheckcmd'              => $opt_p,
                    'services_per_host'         => ceil($opt_s/100),
                    'servicecheckcmd'           => $opt_p,
                    'host_settings'             => {
                            'normal_check_interval' => 1,
                            'retry_check_interval'  => 1,
                    },
                    #'host_types'                => { 'up' => 100 },
                    'service_settings'          => {
                            'normal_check_interval' => 1,
                            'retry_check_interval'  => 1,
                    },
                    #'service_types'             => { 'ok' => 100 },
);
$ngt->create();
