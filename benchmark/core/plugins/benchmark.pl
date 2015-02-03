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
my $resultdir      = $ARGV[0] || die("no result dir given");
my $nice           = "nice -n 10"; # this script runs with -10, so adjust back to 0

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
my $lr    = sub {
    my $min1 = time() - 60;
    return $class->table('services')->stats([
        'total'    => { -isa => { -and => [ 'description' => { '!=' => '' } ]}},
        'pending'  => { -isa => { -and => [ 'has_been_checked' => 0 ]}},
        'ok'       => { -isa => { -and => [ 'has_been_checked' => 1, 'state' => 0 ]}},
        'warning'  => { -isa => { -and => [ 'has_been_checked' => 1, 'state' => 1 ]}},
        'critical' => { -isa => { -and => [ 'has_been_checked' => 1, 'state' => 2 ]}},
        'unknown'  => { -isa => { -and => [ 'has_been_checked' => 1, 'state' => 3 ]}},
        'lastmin'  => { -isa => { -and => [ 'has_been_checked' => 1, 'last_check' => { '>=' => $min1 } ]}},
        'latency'  => { -isa => [ -avg => 'latency' ]},
    ])
};
my $stats = Catalyst::Stats->new;

###########################################################
# clean up
print $ENV{OMD_SITE}.":\n";
`rm -f var/nagios/* var/nagios/archive/* var/icinga/* var/icinga/archive/* var/naemon/* var/icinga2/* 2>&1`;

###########################################################
# start gently
my $testservices = $startwith;
adjust_services($testservices, 1);
my $interval = `grep normal_check_interval recreate.pl|tail -n 1`; $interval =~ s/\s*'normal_check_interval' => //g; $interval =~ s/,//g; chomp($interval); $interval = $interval*60;

###########################################################
# benchmark
$stats->profile(begin => 'omd start');
print "  -> starting core...";
`$nice omd start`;
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
# wait till our cpu usage is low
my($r, $b, $swpd, $free, $buff, $cache, $si, $so, $bi, $bo, $in, $cs, $us, $sy, $id, $wa);
while(!defined $last_vmstat || $id < 90) {
    print "  -> waiting for start, cpu idle ".($id || '?')."% ...\n";
    sleep 3;
    ($r, $b, $swpd, $free, $buff, $cache, $si, $so, $bi, $bo, $in, $cs, $us, $sy, $id, $wa) = split/\s+/, $last_vmstat;
}

###########################################################
$stats->profile(begin => 'running test');
my $plugin = $testplugin;
$plugin =~ s/^.*\///gmx;
my $file = $resultdir.'/'.$ENV{OMD_SITE}.'_'.$plugin.'.csv';
print "  -> opening csv ".$file." ...";
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
my $highest_rate   = 0;
print "starting loop\n";
my $scaninterval = $shortinterval;
while(1) {
    while($last_inc_check > time() - $updateinterval) {
        sleep($scaninterval);
        my $now         = time();
        my $lstat       = get_livestatus_stats($ls);
        $checkstats     = get_livestatus_stats(&{$lr}());
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
    printf("checking... (idle: %d, latency: %.1f, rate: %.1f, expected rate: %.1f, max rate: %.1f)\n", $id, $checkstats->{latency}, $rate, $avg, $highest_rate);
    my $ok = 0;
    if($id > 50)            { $ok = 1; print "  -> idle $id > 50%\n";  }
    elsif($rate/$avg > 0.9) { $ok = 1; print "  -> rate ".int($rate)." > 90%\n"; }
    else {
        if(!($checkstats->{pending} == 0 or ($checkstats->{pending}/$checkstats->{total})<=0.5))  { print "  -> pending must be less than 50%, have ".int($checkstats->{pending}/$checkstats->{total}*100)."%\n"; }
        elsif(!(($checkstats->{ok}+$checkstats->{pending})/$checkstats->{total} > 0.7))           { print "  -> ok+pending < 70%\n"; }
        elsif(!($id > 10))                                                                        { print "  -> idle $id < 10%\n"; }
        elsif(!($checkstats->{latency} <= 10))                                                    { print "  -> latency > 10\n"; }
        elsif(!($highest_rate > 10 && $rate > $highest_rate *0.85))                               { print "  -> 85% of highest rate missed\n"; }
        elsif(!($avg > 50 && $rate/$avg > 0.8))                                                   { print "  -> 80% of expected rate missed, ".int($rate/$avg*100)."\n"; }
        else { $ok = 1; }
    }
    if($ok) {
        my $inc = 10;
        if(   $testservices <   100) { $inc =   10; }
        elsif($testservices <   500) { $inc =   50; }
        elsif($testservices <  1000) { $inc =  100; }
        elsif($testservices <  5000) { $inc =  500; }
        elsif($testservices < 20000) { $inc = 1000; }
        elsif($testservices < 50000) { $inc = 5000; }
        else { $inc = 10000; }
        if(   $id > 90) { $inc = $inc * 3; }  # find peak faster
        elsif($id > 70) { $inc = $inc * 2; }
        elsif($id < 10) { $inc = $inc / 2; }
        $testservices += $inc;
        $testservices = ceil(ceil($testservices / $inc)*$inc);
        adjust_services($testservices);
        $last_lstat   = get_livestatus_stats($ls);
        $lastcheck    = time();
        $failed       = 0;
    } else {
        if(($failed +1) >= $max_retry) {
            print "we are done (".($failed+1)."/".$max_retry.")\n";
            last;
        } else {
            print "retry (".($failed+1)."/".$max_retry.")\n";
        }
        $failed++;
    }
    $last_inc_check = time();
    $highest_rate   = $rate if $rate > $highest_rate;
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
    my $plugin = $testplugin;
    if($plugin !~ m/^\//mx) { $plugin = $ENV{'OMD_ROOT'}."/local/lib/nagios/plugins/$testplugin";  }
    print "  -> setting services to $testservices (".$ENV{OMD_SITE}." / $testplugin)...";
    `./local/lib/nagios/plugins/create_test_config.pl -p "$plugin" -s "$testservices"`;
    if($ENV{'OMD_SITE'} =~ m/icinga2/mx) {
        unlink("etc/nagios/conf.d/check_mk_templates.cfg");
        unlink("etc/nagios/conf.d/jmx4perl_nagios.cfg");
        unlink("etc/nagios/conf.d/notification_commands.cfg");
        unlink("etc/nagios/conf.d/timeperiods.cfg");
        unlink("etc/nagios/conf.d/templates.cfg");
        unlink("etc/icinga2/conf.d/services.conf");
        unlink("etc/icinga2/conf.d/hosts.conf");
        `cd icinga2-migration/ && ./bin/icinga-conftool migrate v1 ~/etc/icinga/icinga.d/omd.cfg > ~/etc/icinga2/conf.d/migration.conf`;
        `sed -i -e 's/\\\\@/@/g' etc/icinga2/conf.d/migration.conf`;
    }
    unless($no_restart) {
        unlink('tmp/run/live');
        if($ENV{OMD_SITE} =~ m/shinken/) {
            `$nice omd restart core`;
        } else {
            `$nice omd reload core`;
        }
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

    if($checkstats->{lastmin} > 0 && $servicecheckrate == 0) {
        printf("no rate from status table, had to calculate rate from lastchecks...\n");
        $servicecheckrate = $checkstats->{lastmin}/$checkstats->{total};
    }

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
    for my $x (1..30) {
        eval {
            alarm(30);
            $stat = $ls->hashref_array()->[0];
            die("no data") unless defined $stat;
        };
        alarm(0);
        if($@) {
            sleep(1);
            if($x%10 == 0) { `$nice omd restart core`; }
            elsif($x%5 == 0) { `$nice omd start core`; }
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
