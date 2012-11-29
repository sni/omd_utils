#!/usr/bin/perl

use warnings;
use strict;
use Monitoring::Livestatus::Class;
use POSIX;
use IO::Handle;

###########################################################
# settings
my $checkinterval  = 10;

###########################################################
$| = 1;
my $class = Monitoring::Livestatus::Class->new( peer => 'tmp/run/live');
my $ls    = $class->table('status')->columns(qw/host_checks service_checks/);
my $lr    = $class->table('services')->stats([
        'total'    => { -isa => { -and => [ 'description' => { '!=' => '' } ]}},
        'pending'  => { -isa => { -and => [ 'has_been_checked' => 0 ]}},
        'ok'       => { -isa => { -and => [ 'has_been_checked' => 1, 'state' => 0 ]}},
        'warning'  => { -isa => { -and => [ 'has_been_checked' => 1, 'state' => 1 ]}},
        'critical' => { -isa => { -and => [ 'has_been_checked' => 1, 'state' => 2 ]}},
        'unknown'  => { -isa => { -and => [ 'has_been_checked' => 1, 'state' => 3 ]}},
        'latency'  => { -isa => [ -avg => 'latency' ]},
]);

my $interval = `grep normal_check_interval recreate.pl|tail -n 1`; $interval =~ s/\s*'normal_check_interval' => //g; $interval =~ s/,//g; chomp($interval); $interval = $interval*60;

my $file  = '/opt/share/build/sven/result/'.$ENV{OMD_SITE}.'.csv';
open(my $fh, '>', $file) or die("failed to open csv: $!");
print $fh join(",",qw/time
                      hostchecks hostcheckrate
                      servicechecks servicecheckrate
                      avg_checks services
                      latency
                      running blocked
                      swpd free buff cache
                      swapin swapout
                      ioblockin ioblockout
                      system_interrupts context_switches
                      cpu_user cpu_sys cpu_idle cpu_wait
                     /),"\n";

my $start      = time();
my $lastcheck  = $start;
my $last_lstat = get_livestatus_stats($ls);
open(my $vp, 'vmstat '.($checkinterval-1).'|') or die("failed to start vmstat");
while(<$vp>) {
    sleep($checkinterval);
    my $vmstat;
    chomp($vmstat = $_);
    $vmstat         =~ s/^\s+//gmx;
    my $now         = time();
    my $lstat       = get_livestatus_stats($ls);
    my $checkstats  = get_livestatus_stats($lr);
    my($rate, $avg) = update_csv($fh, $start, $now, $lastcheck, $checkstats->{total}, $vmstat, $lstat, $last_lstat, $checkstats);
    printf("elapsed: %4s,     testservices: %5s,     ok: %5s,     pending: %5s,     rate: %.1f,     exp: %.1f\n", ($now-$start), $checkstats->{total}, $checkstats->{ok}, $checkstats->{pending}, $rate, $avg);
    $last_lstat = $lstat;
    $lastcheck  = $now;
}
close($vp);
exit;

close($fh);
print "$file written\n";
exit;

###########################################################
# write new entry in our csv
sub update_csv {
    my($fh, $start, $now, $lastcheck, $testservices, $vmstat, $lstat, $last_lstat, $checkstats) = @_;
    my $elapsed          = $now - $lastcheck;
    my $avg_checks       = sprintf("%.1f", ($testservices / $interval));

    return(0,$avg_checks) unless defined $lastcheck and defined $last_lstat;

    my($r, $b, $swpd, $free, $buff, $cache, $si, $so, $bi, $bo, $in, $cs, $us, $sy, $id, $wa) = split/\s+/, $vmstat;

    my $hostchecks       = $lstat->{'host_checks'};
    my $hostcheckrate    = ($lstat->{'host_checks'}-$last_lstat->{'host_checks'}) / $elapsed;
    my $servicechecks    = $lstat->{'service_checks'};
    my $servicecheckrate = ($lstat->{'service_checks'}-$last_lstat->{'service_checks'}) / $elapsed;
    my $latency          = $checkstats->{latency};
    print $fh join(",", ($now-$start),
                        $hostchecks, sprintf("%.2f", $hostcheckrate),
                        $servicechecks, sprintf("%.2f", $servicecheckrate),
                        $avg_checks, $testservices,
                        sprintf("%.2f", $latency),
                        $r, $b,
                        $swpd,
                        $free, $buff, $cache,
                        $si, $so,
                        $bi, $bo,
                        $in, $cs,
                        $us, $sy, $id, $wa,
                        ),"\n";
    $fh->flush;
    return($servicecheckrate, $avg_checks);
}

###########################################################
sub get_livestatus_stats {
    my $ls = shift;
    my $stat;
    for my $x (1..10) {
        eval {
            alarm(30);
            $stat = $ls->hashref_array()->[0];
            die("no data") unless defined $stat;
        };
        alarm(0);
        if($@) {
            sleep(1);
        } else {
            return $stat;
        }
    }
    die("no livestatus answer!!! core failed??");
}

###########################################################
