#!/usr/bin/perl

use warnings;
use strict;
use threads;
use threads::shared;
use Data::Dumper;
use Catalyst::Stats;
use Monitoring::Livestatus::Class;
use POSIX;
use IO::Handle;

###########################################################
# settings
my $testplugin     = $ENV{TEST_COMMAND} || "simple";
my $shortinterval  = 10;       # time between saving statistics till cpu is > 70
my $longinterval   = 60;       # time between saving statistics
my $updateinterval = 120;      # time between increasing checks is 2 minutes
my $max_retry      = 3;
my $startwith      = 10;

### fixed test, no incease
my $fixed = 0;
if($fixed) {
    $startwith      = 120000;
    $updateinterval = 600;     # check duration
    $shortinterval  = 30;
}

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
my $stats = Catalyst::Stats->new;

###########################################################
# clean up
print $ENV{OMD_SITE}.":\n";
`rm -f var/nagios/* var/nagios/archive/* var/icinga/* var/icinga/archive/* 2>&1`;

###########################################################
# start gently
my $testservices = $startwith;
adjust_services($testservices, 1);
my $interval = `grep normal_check_interval recreate.pl|tail -n 1`; $interval =~ s/\s*'normal_check_interval' => //g; $interval =~ s/,//g; chomp($interval); $interval = $interval*60;

###########################################################
# benchmark
$stats->profile(begin => 'omd start');
print "  -> starting core...";
`nice -n 10 omd start`;
for my $x (1..10) { last if -e 'tmp/run/live'; }
print "  done\n";
$stats->profile(end => 'omd start');

my $last_vmstat :shared;
my $thr = threads->create(sub {
    open(my $vp, 'vmstat 9|') or die("failed to start vmstat");
    while(<$vp>) {
        chomp($last_vmstat = $_);
        $last_vmstat =~ s/^\s+//gmx;
    }
    close($vp);
});

###########################################################
$stats->profile(begin => 'running test');
print "  -> opening csv...";
my $plugin = $testplugin;
$plugin =~ s/^.*\///gmx;
my $file  = '/opt/share/build/sven/result/'.$ENV{OMD_SITE}.'_'.$plugin.'.csv';
open(my $fh, '>', $file) or die("failed to open csv $file: $!");
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
print " done\n";
my $start = time();
my($elapsed, $checkstats, $rate, $avg);
my $last_lstat = get_livestatus_stats($ls);
my $lastcheck  = time();
my $failed     = 0;
my $last_inc_check = time();
my($r, $b, $swpd, $free, $buff, $cache, $si, $so, $bi, $bo, $in, $cs, $us, $sy, $id, $wa);
print "starting loop\n";
my $scaninterval = $shortinterval;
while(1) {
    while($last_inc_check > time() - $updateinterval) {
        sleep($scaninterval);
        my $now         = time();
        my $lstat       = get_livestatus_stats($ls);
        $checkstats     = get_livestatus_stats($lr);
        $checkstats->{latency} = 999 unless defined $checkstats->{latency};
        $checkstats->{pending} = 999 unless defined $checkstats->{pending};
        ($rate, $avg)   = update_csv($fh, $start, $now, $lastcheck, $testservices, $last_vmstat, $lstat, $last_lstat, $checkstats);
        printf("elapsed: %4s,     testservices: %5s,     ok: %5s,     pending: %5s,     rate: %.1f,     exp: %.1f\n", ($now-$start), $testservices, $checkstats->{ok}, $checkstats->{pending}, $rate, $avg);
        $lastcheck      = $now;
        $last_lstat     = $lstat;
        ($r, $b, $swpd, $free, $buff, $cache, $si, $so, $bi, $bo, $in, $cs, $us, $sy, $id, $wa) = split/\s+/, $last_vmstat;
        unless($fixed) {
            last if $id > 30 or ($rate/$avg > 0.90) # quick increase
        }
    }
    last if $fixed;

    $scaninterval = $longinterval if $id < 30;

    # check if there are ressources for more
    printf("checking... (idle: %d, latency: %.1f, rate: %.1f, expected rate: %.1f)\n", $id, $checkstats->{latency}, $rate, $avg);
    if(
       (($checkstats->{ok}+$checkstats->{pending})/$checkstats->{total} > 0.9 # more than 90% of the checks are ok
        and $checkstats->{latency} <= 10   # latency below 20seconds (seems to be always 0 in nagios4)
        and ($checkstats->{pending} == 0 or ($checkstats->{pending}/$checkstats->{total}) < 0.5) # less than 50% are pending
        and $id > 10            # when idling
        )
        or $id > 30            # when turbo idling, quick pass
        or ($rate/$avg > 0.95) # or checkrate is at least 90% of the target
    ) {
        my $inc = 10;
        if(   $testservices <   100) { $inc =   10; }
        elsif($testservices <   500) { $inc =   50; }
        elsif($testservices <  1000) { $inc =  100; }
        elsif($testservices <  5000) { $inc =  500; }
        elsif($testservices < 20000) { $inc = 1000; }
        elsif($testservices < 50000) { $inc = 5000; }
        else { $inc = 10000; }
        if($id > 90)    { $inc = $inc * 3; }  # find peak faster
        elsif($id > 85) { $inc = $inc * 2; }
        elsif($id < 5)  { $inc = $inc / 3; }
        elsif($id < 10) { $inc = $inc / 2; }
        $testservices += $inc;
        $testservices = ceil(ceil($testservices / $inc)*$inc);
        adjust_services($testservices);
        $last_lstat   = get_livestatus_stats($ls);
        $lastcheck    = time();
        $failed       = 0;
    } else {
        if($failed >= $max_retry) {
            print "we are done (".$failed."/".$max_retry.")\n";
            last;
        } else {
            print "retry (".$failed."/".$max_retry.")\n";
        }
        $failed++;
    }
    $last_inc_check = time();
}
$stats->profile(end => 'running test');
`killall $testplugin 2>/dev/null`;
`omd stop`;

###########################################################
# calculate report
print $stats->report ."\n";

close($fh);
print "$file written\n";
exit;

###########################################################
# set new services checks
sub adjust_services {
    my($testservices, $no_restart) = @_;
    print "  -> setting services to $testservices...";
    my $plugin = $testplugin;
    if($plugin !~ m/^\//mx) { $testplugin = "\\\$USER2\\\$/$testplugin";  }
    `./local/lib/nagios/plugins/create_test_config.pl -p $plugin -s $testservices`;
    unless($no_restart) {
        unlink('tmp/run/live');
        `omd reload core`;
        for my $x (1..10) { last if -e 'tmp/run/live'; sleep(1); }
    }
    print " done\n";
}

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
if($servicecheckrate < 0) {
use Data::Dumper; print STDERR Dumper($now);
use Data::Dumper; print STDERR Dumper($start);
use Data::Dumper; print STDERR Dumper($lastcheck);
use Data::Dumper; print STDERR Dumper($elapsed);
use Data::Dumper; print STDERR Dumper($lstat);
use Data::Dumper; print STDERR Dumper($last_lstat);
}

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
            if($x == 5) { `omd start core`; }
        } else {
            return $stat;
        }
    }
    die("no livestatus answer!!! core failed??");
}

###########################################################
END {
    `killall $testplugin 2>/dev/null`;
    `omd stop`;
    exit;
}

###########################################################
