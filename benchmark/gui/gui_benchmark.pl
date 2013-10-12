#!/usr/bin/perl

use strict;
use warnings;
use File::Which;
use Getopt::Long;
use JSON::XS qw/decode_json encode_json/;
use File::Slurp;
use Monitoring::Livestatus::Class;
use Monitoring::Generator::TestConfig;

die('please only run in a OMD site') unless defined $ENV{'OMD_SITE'};
$ENV{'PATH'} .= $ENV{'PATH'}.':/usr/sbin';

############################################################
# Settings
my $verbose = 0;
my $num_services_to_test = [1,5000,10000,15000,20000,25000,30000,35000,40000,45000,50000,55000,60000];
my $reqs        = 100;
my $concur      = 5;
my $inter_sleep = 2;
my $auth        = 'omdadmin:omd';
my $site        = $ENV{'OMD_SITE'};
my $AB          = which('ab') || die "Cannot locate apache benchmark tool ab";
my $csvsep      = ';';
my $tests       = {
   #'Tactical Overview' => {
   #    'Nagios'    => 'http://localhost/'.$site.'/nagios/cgi-bin/tac.cgi',
   #    'Icinga'    => 'http://localhost/'.$site.'/icinga/cgi-bin/tac.cgi',
   #    'Thruk'     => 'http://localhost/'.$site.'/thruk/cgi-bin/tac.cgi',
   # },
   'Service Problems' => {
      'Nagios'    => 'http://localhost/'.$site.'/nagios/cgi-bin/status.cgi?host=all&servicestatustypes=28',
      'Icinga'    => 'http://localhost/'.$site.'/icinga/cgi-bin/status.cgi?host=all&servicestatustypes=28',
      'Thruk'     => 'http://localhost/'.$site.'/thruk/cgi-bin/status.cgi?host=all&servicestatustypes=28',
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
# params
my($number, $only_tool);
GetOptions (
    "v|verbose:+"  => \$verbose,
    "r|reqs=i"     => \$reqs,
    "n|num=i"      => \$number,
    "c|concur=i"   => \$concur,
    "t|tool=s"     => \$only_tool,
    "h|?|help"     =>
       sub {
          printf "usage:\n\t%s\n", join("\n\t", (
             "-h, --help",
             "-v, --verbose",
             "-r, --reqs      - Number of requests",
             "-c, --concur    - Number of concurrent requests",
             "-n, --num       - Number of services to create",
             "-t, --tool      - Check this tool only, one of Thruk, Icinga or Nagios",
          ));
          exit 1;
       },
) or die "Error specifying cmdline options";
$num_services_to_test = [split(/,/mx,$number)] if $number;

############################################################
# prepare our site
chdir($ENV{'OMD_ROOT'});
create_test_config("1");
if ($verbose) {
    system('omd stop');
    system('omd start');
} else {
    system('omd stop >/dev/null 2>&1');
    system('omd start >/dev/null 2>&1');
}
unlink('tmp/icinga/icinga.cfg');
`ln -s ../nagios/nagios.cfg tmp/icinga/icinga.cfg`;


############################################################
# run the benchmark
my $results = {};
if(-f 'results.json') { $results = decode_json(read_file('results.json')); }
for my $num (@{$num_services_to_test}) {
    prepare_test($num);
    printf "\n%s\n/// %6d services, %2d concurrent req, %3d requests   %24s ///\n%s\n",
       '/' x 83, $num, $concur, $reqs, scalar(localtime), '/' x 83;
    for my $test (keys %{$tests}) {
        print "$test:\n";
        for my $tool (sort keys %{$tests->{$test}}) {
            next if(defined $only_tool and $only_tool ne $tool);
            sleep($inter_sleep);
            my $url = $tests->{$test}->{$tool};
            my(@avgs,@rates);
            for (1..3) {
                my($avg,$rate) = bench($url);
                sleep(1);
                push @avgs,  $avg  if $avg  ne '';
                push @rates, $rate if $rate ne '';
            }
            @avgs = sort { $a <=> $b } @avgs;
            my $avg = defined $avgs[0] ? $avgs[0] : '';
            @rates = sort { $b <=> $a } @rates;
            my $rate = defined $rates[0] ? $rates[0] : '';
            printf("%10s -> avg %5d ms, rate % 8.2f\n", $tool, $avg, $rate);
            $results->{'avg'}->{$test}->{$tool}->{$num}  = sprintf "%.2f ",$avg/1000;
            $results->{'rate'}->{$test}->{$tool}->{$num} = sprintf "%.2f ",$rate;
            sleep(3);
        }
    }
    write_out_csv();
}

exit(0);

############################################################
# SUBS
############################################################
sub bench {
    my $url = shift;
    my $nr  = shift || 0;
    return '' if $nr >= 3;

    my $cmdopts="-n $reqs -c $concur -A $auth";
    $cmdopts.=" -v $verbose" if ($verbose);
    my $cmd = "$AB $cmdopts '$url'";
    print "cmd: $cmd\n" if ($verbose >= 2) ;
    my $out = `$cmd 2>&1`;

    $out =~ m/Complete\s+requests:\s+(\d+)/mx;
    my $complete = $1;

    $out =~ m/Time\s+per\s+request:\s+([\d\.]+)/mx;
    my $avg = $1;

    $out =~ m/Requests\s+per\s+second:\s+([\d\.]+)/mx;
    my $rate = $1;

    if($complete != $reqs) {
        printf("ERROR: complete:%d, avg:%d, rate:% 8.2f in %s\n", $complete, $avg, $rate, $url) if ($verbose >= 2);
        $nr++;
        sleep(3);
        return(bench($url, $nr));
    }
    printf("complete:%d, avg:%d, rate:% 8.2f in %s\n", $complete, $avg, $rate, $url) if ($verbose >= 2);
    return($avg, $rate);
}

############################################################
sub prepare_test {
    my $num = shift;
    my $now  = time();
    system('>./var/nagios/livestatus.log');
    system('>./var/nagios/nagios.log');
    cmdpipe("[$now] STOP_EXECUTING_HOST_CHECKS\n");
    cmdpipe("[$now] STOP_EXECUTING_SVC_CHECKS\n");
    create_test_config($num);
    `./etc/init.d/nagios reload`;
    `./etc/init.d/thruk start`;
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
    local $SIG{'ALRM'} = sub { die("timeout while waiting for nagios.cmd") };
    alarm(5);
    open(my $fh, '>>', 'tmp/run/nagios.cmd') or die('cannot open pipe: '.$!);
    print $fh $txt;
    close($fh);
    alarm(0);
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

############################################################
# print result as csv
sub write_out_csv  {
    # now combine into single result
    my $file = "results.json";
    open(my $fh, '>', $file) or die("cannot write results to ".$file.": ".$!);
    print $fh JSON::XS->new->utf8->pretty->encode($results),"\n";
    close($fh);
    for my $prefix (qw/avg rate/) {
        my $file = sprintf("results_%s.csv", $prefix);
        open(my $fh, '>', $file) or die("cannot write results to ".$file.": ".$!);
        for my $test (keys %{$results->{$prefix}}) {
            print $fh $test,"\n";
            # get all numbers
            my $numbers;
            for my $tool (keys %{$results->{$prefix}->{$test}}) {
                push @{$numbers}, keys %{$results->{$prefix}->{$test}->{$tool}};
            }
            $numbers = sort_uniq($numbers);

            print $fh ''.$csvsep.join($csvsep, @{$numbers})."\n";
            for my $tool (sort keys %{$results->{$prefix}->{$test}}) {
                print $fh $tool, $csvsep;
                for my $num (@{$numbers}) {
                    print $fh ($results->{$prefix}->{$test}->{$tool}->{$num} || ''), $csvsep;
                }
                print $fh "\n";
            }
            print $fh "\n";
        }
        close($fh);
        print "results_".$prefix.".csv written\n";
    }
}

############################################################
sub sort_uniq {
    my($list) = @_;
    my %uniq;
    for my $x (@{$list}) { $uniq{$x} = 1; }
    my @new_list = sort { $a <=> $b } keys %uniq;
    return \@new_list;
}
