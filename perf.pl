#!/usr/bin/perl

use strict;
use warnings;
use File::Which;
use Monitoring::Livestatus::Class;
use Monitoring::Generator::TestConfig;

die('please only run in a OMD site') unless defined $ENV{'OMD_SITE'};
$ENV{'PATH'} .= $ENV{'PATH'}.':/usr/sbin';

############################################################
# Settings
my $verbose = 0;
my $num_services_to_test = [1,10,100,500,1000,2000,5000,7500,10000,15000,20000];
my $reqs    = 100;
my $concur  = 5;
my $site    = $ENV{'OMD_SITE'};
my $AB      = which('ab') || die "Cannot locate apache benchmark tool ab";
my $csvsep  = ';';
my $tests   = {
   'Tactical Overview' => {
      'Nagios'    => 'http://localhost/'.$site.'/nagios/cgi-bin/status.cgi?host=all&servicestatustypes=28',
      'Icinga'    => 'http://localhost/'.$site.'/icinga/cgi-bin/status.cgi?host=all&servicestatustypes=28',
      'Thruk'     => 'http://localhost/'.$site.'/thruk/cgi-bin/status.cgi?host=all&servicestatustypes=28',
    },
   'Service Problems' => {
       'Nagios'    => 'http://localhost/'.$site.'/nagios/cgi-bin/tac.cgi',
       'Icinga'    => 'http://localhost/'.$site.'/icinga/cgi-bin/tac.cgi',
       'Thruk'     => 'http://localhost/'.$site.'/thruk/cgi-bin/tac.cgi',
    },
   'Process Info' => {
       'Nagios'    => 'http://localhost/'.$site.'/nagios/cgi-bin/extinfo.cgi?type=0',
       'Icinga'    => 'http://localhost/'.$site.'/icinga/cgi-bin/extinfo.cgi?type=0',
       'Thruk'     => 'http://localhost/'.$site.'/thruk/cgi-bin/extinfo.cgi?type=0',
    },
   'Event Log' => {
       'Nagios'    => 'http://localhost/'.$site.'/nagios/cgi-bin/showlog.cgi',
       'Icinga'    => 'http://localhost/'.$site.'/icinga/cgi-bin/showlog.cgi',
       'Thruk'     => 'http://localhost/'.$site.'/thruk/cgi-bin/showlog.cgi',
    },
};

############################################################
# prepare our site
chdir($ENV{'OMD_ROOT'});
system('omd start >/dev/null 2>&1');

############################################################
# run the benchmark
my $result = {};
for my $num (@{$num_services_to_test}) {
    system('>./var/nagios/livestatus.log');
    system('>./var/nagios/nagios.log');
    unlink('./var/nagios/retention.dat');
    prepare_test($num);
    for my $test (keys %{$tests}) {
        print "$test - $num services:\n";
        for my $tool (keys %{$tests->{$test}}) {
            my $url = $tests->{$test}->{$tool};
            my @avgs;
            for (1..5) {
                my($avg) = bench($url);
                sleep(1);
                push @avgs, $avg if $avg ne '';
            }
            @avgs = sort { $a <=> $b } @avgs;
            my $avg = defined $avgs[0] ? $avgs[0] : '';
            print "$tool -> avg $avg ms\n";
            push @{$result->{$test}->{$tool}}, sprintf "%.2f ",$avg/1000;
            sleep(3);
        }
    }
}

############################################################
# print result as csv
for my $test (keys %{$tests}) {
    print $test."\n";
    print 'Services'.$csvsep.join($csvsep, @{$num_services_to_test})."\n";
    for my $tool (keys %{$tests->{$test}}) {
        print $tool.$csvsep.join($csvsep, @{$result->{$test}->{$tool}})."\n";
    }
    print "\n";
}
exit(0);

############################################################
# SUBS
############################################################
sub bench {
    my $url = shift;
    my $nr  = shift || 0;
    return '' if $nr >= 3;

    my $cmd = "$AB -n $reqs -c $concur -A omdadmin:omd '$url'";
    print "cmd: $cmd\n" if $verbose;
    my $out = `$cmd 2>&1`;
    $out =~ m/Failed\s+requests:\s+(\d+)/mx;
    my $failed = $1;

    $out =~ m/Complete\s+requests:\s+(\d+)/mx;
    my $complete = $1;

    $out =~ m/Time\s+per\s+request:\s+([\d\.]+)/mx;
    my $avg = $1;

    if($failed > 0 or $complete != $reqs) {
        print "ERROR: complete:$complete, failed:$failed, avg:$avg in $url\n";
        $nr++;
        sleep(3);
        return(bench($url, $nr));
    }
    return($avg);
}

############################################################
sub prepare_test {
    my $num = shift;
    my $now  = time();
    cmdpipe("[$now] STOP_EXECUTING_HOST_CHECKS\n");
    cmdpipe("[$now] STOP_EXECUTING_SVC_CHECKS\n");
    create_test_config($num);
    `./recreate.pl`;
    `./etc/init.d/nagios reload`;
    sleep(3);
    reschedule();
}

############################################################
sub reschedule {
    my $nr    = 0;
    my $now   = time();
    my $class = Monitoring::Livestatus::Class->new(peer => './tmp/run/live');
    my $data  = $class->table('services')->columns(qw/host_name description/)->filter({'active_checks_enabled' => 1})->hashref_array();;
    open(my $fh, '>', './tmp/nagios/checkresults/cqhZOHU') or die('cannot write to checkresults dir: '.$!);
    for my $row (@{$data}) {
        next unless $nr%20==0;
        print $fh "### Nagios Service Check Result ###\n";
        print $fh "# Time: Tue Nov  8 11:48:30 2011\n";
        print $fh "host_name=$row->{'host_name'}\n";
        print $fh "service_description=$row->{'description'}\n";
        print $fh "check_type=0\n";
        print $fh "check_options=1\n";
        print $fh "start_time=$now.44148\n";
        print $fh "finish_time=$now.76907\n";
        print $fh "early_timeout=0\n";
        print $fh "exited_ok=1\n";
        print $fh "return_code=1\n";
        print $fh "output=blah\n";

        $nr++;
    }
    close($fh);
    open($fh, '>', './tmp/nagios/checkresults/cqhZOHU.ok') or die('cannot write to checkresults dir: '.$!);
    close($fh);
    while(-f './tmp/nagios/checkresults/cqhZOHU.ok') {
      sleep(1);
    }
    sleep(2);
}

############################################################
sub cmdpipe {
    my $txt = shift;
    open(my $fh, '>>', 'tmp/run/nagios.cmd') or die('cannot open pipe: '.$!);
    print $fh $txt;
    close($fh);
}

############################################################
sub create_test_config {
   my $hostnum = shift;
   my $ngt = Monitoring::Generator::TestConfig->new(
       'hostcount'         => $hostnum,
       'hostcheckcmd'      => '/bin/hostname',
       'servicecheckcmd'   => '/bin/false',
       'skip_dependencys'  => 1,
       'routercount'       => 0,
       'services_per_host' => 1,
   );
   open(CPOUT, ">&STDOUT");
   open(STDOUT, ">/dev/null") || die "Error stdout: $!";
   $ngt->create();
   close(STDOUT) || die "Can't close STDOUT: $!";
   open(STDOUT, ">&CPOUT") || die "Can't restore stdout: $!";
   close(CPOUT);
}
