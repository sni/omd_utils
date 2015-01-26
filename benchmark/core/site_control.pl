#!/usr/bin/perl

use warnings;
use strict;
use File::Copy "cp";
use Data::Dumper;

my $siteconfig = {
    'nagios3'         => { core => 'nagios'  },
    'naemon'          => { core => 'naemon'  },
    'icinga1'         => { core => 'icinga'  },
    'icinga2'         => { core => 'icinga2' },
    'shinken'         => { core => 'shinken' },
    'nagios3_gearman' => { core => 'nagios', },
    'naemon_gearman'  => { core => 'naemon', },
    'icinga_gearman'  => { core => 'icinga', },
};
my @sites = qw/nagios3 naemon icinga1 icinga2 shinken nagios3_gearman naemon_gearman icinga_gearman/;
my $plugins = [ 'simple', 'simple.pl', 'simple.sh', 'benchmark.pl', 'create_test_config.pl', 'big.pl', 'big_epn.pl', 'simple_epn.pl' ];

#################################################
if(scalar @ARGV == 0) { usage(); }
my $action = shift @ARGV;
if(defined $ENV{'TEST_SITES'}) { @sites = split/\s+/, $ENV{'TEST_SITES'}; }
if(scalar @ARGV > 0) { @sites = @ARGV; }
for my $site (@sites) { $site =~ s/"//g };
if($action eq 'create') { create_sites(); }
elsif($action eq 'clean')  { clean_sites(); }
elsif($action eq 'benchmark')  { benchmark_sites(); }
else { print "unknown argument\n\n"; usage(); }
exit;

#################################################
# SUBS
#################################################
sub usage {
    print "usage: $0 create|benchmark|clean [site ...]\n";
    exit 3;
}

#################################################
sub create_sites {
    my $proxy = "";
    for my $key (qw/HTTP_PROXY HTTPS_PROXY http_proxy https_proxy/) {
        if($ENV{$key}) { $proxy .= " ".$key."=".$ENV{$key}; }
    }
    for my $site (@sites) {
        my $core = $siteconfig->{$site}->{core} || die("unknown site: $site");
        print "creating ".$site."...";
        `omd create $site` unless -d '/omd/sites/'.$site;
        print " done\n";

        print "  -> set core...";
        `omd stop $site 2>/dev/null`;
        `omd config $site set CORE $core`;
        `omd config $site set AUTOSTART off`;
        `omd config $site set PNP4NAGIOS off`;
        print " done\n";

        print "  -> install perl modules...";
        `su - $site -c '$proxy cpanm -n Monitoring::Generator::TestConfig'`;
        print " done\n";

        update_plugins($site);

        `su - $site -c "sed -e 's/enable_embedded_perl=0/enable_embedded_perl=1/'                 -i etc/nagios/nagios.d/misc.cfg -i etc/icinga/icinga.d/misc.cfg"`;
        `su - $site -c "sed -e 's/use_embedded_perl_implicitly=1/use_embedded_perl_implicitly=0/' -i etc/nagios/nagios.d/misc.cfg -i etc/icinga/icinga.d/misc.cfg"`;

        if($site =~ m/gearman/mx) {
            `su - $site -c 'omd config set MOD_GEARMAN on'`;
        }

        my $extra_command = $siteconfig->{$site}->{extra_command};
        if(defined $extra_command) {
            print "  -> extra config settings...";
            `su - $site -c '$extra_command'`;
            print " done\n";
        }

        print "  -> site created\n";
    }
}

#################################################
sub benchmark_sites {
    chomp(my $pwd = `pwd`);
    `mkdir -p /var/tmp/coreresults`;
    `chmod 777 /var/tmp/coreresults`;
    for my $site (@sites) {
        my $command = "";

        # just to make sure
        update_plugins($site);

        if(defined $ENV{'TEST_COMMAND'}) {
            $command = "TEST_COMMAND=".$ENV{'TEST_COMMAND'}." ";
        }
        if(defined $ENV{'TEST_HOSTS'}) {
            $command .= "TEST_HOSTS=".$ENV{'TEST_HOSTS'}." ";
        }
        if(defined $ENV{'TEST_SERVICES'}) {
            $command .= "TEST_SERVICES=".$ENV{'TEST_SERVICES'}." ";
        }
        if(defined $ENV{'TEST_DURATION'}) {
            $command .= "TEST_DURATION=".$ENV{'TEST_DURATION'}." ";
        }
        print "running benchmark: ".$site." ".($command ne '' ? "(".$ENV{'TEST_COMMAND'}.")" : "")." -> ".(scalar localtime)."\n";
        my $cmd = "nice -n -10 su - $site -c '$command./local/lib/nagios/plugins/benchmark.pl /var/tmp/coreresults'";
        open(my $ph, "$cmd |") or die("failed to exec '".$cmd."': $!");
        while(<$ph>) { print $_; }
        close($ph);
        print "  -> finished benchmark\n";

        print "stoping site...";
        `su - $site -c 'omd stop core'`;
        print " done\n";
    }
}


#################################################
sub clean_sites {
    for my $site (@sites) {
        print "removing ".$site."...\n";
        `yes yes | omd rm $site` if -d '/omd/sites/'.$site;
        print "  -> done\n";
    }
}

#################################################
sub update_plugins {
    my $site = shift;
    print "  -> copy check plugins\n";
    for my $plugin (@{$plugins}) {
        unlink('/omd/sites/'.$site.'/local/lib/nagios/plugins/'.$plugin);
        cp("plugins/".$plugin,  '/omd/sites/'.$site.'/local/lib/nagios/plugins');
    }
    `chown $site: /omd/sites/$site/local/lib/nagios/plugins/*`;
    `chmod 755 /omd/sites/$site/local/lib/nagios/plugins/*`;
    return;
}
