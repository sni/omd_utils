#!/usr/bin/env perl

use warnings;
use strict;
use Data::Dumper;
use File::ChangeNotify;
use File::Spec;

############################################################
# Settings
my $app_root = '###THRUK###';
my $pidfile  = $ENV{'OMD_ROOT'}."/tmp/run/thruk_restarter.lock";

############################################################
_check_lock();
$| = 1;

############################################################
my $filter   = qr/(?:\/|^)(?![.#_]).+(?:\.yml$|\.yaml$|\.conf|\.pm|\.tt)$/;
my $exclude  = [
        File::Spec->catdir($app_root, 't'),
        File::Spec->catdir($app_root, 'root'),
        qr(/\.[^/]*/?$),    # match hidden dirs
];
my @plugins = glob($ENV{'OMD_ROOT'}.'/etc/thruk/plugins-enabled/*/lib');
my $directories = [
                      $app_root."/lib",
                      $app_root."/plugins",
                      $app_root."/script",
                      $app_root."/templates",
                      $ENV{'OMD_ROOT'}.'/etc/thruk',
		      @plugins,
];
my $watcher =
    File::ChangeNotify->instantiate_watcher(
        directories => $directories,
        filter      => $filter,
        exclude     => $exclude,
);

_log("$0 started with $$");
while (1) {
    my @events = $watcher->wait_for_events();
    _handle_events(@events);
}
unlink($pidfile);
exit;

############################################################
sub _handle_events {
    my @events = @_;

    my @files;
    # Filter out any events which are the creation / deletion of directories
    # so that creating an empty directory won't cause a restart
    for my $event (@events) {
        my $path = $event->path();
        my $type = $event->type();
        if (   ( $type ne 'delete' && -f $path )
            || ( $type eq 'delete' && $path =~ $filter ) )
        {
            push @files, { path => $path, type => $type };
        }
    }

    if (@files) {
        _log("Saw changes to the following files:");

        for my $f (@files) {
            my $path = $f->{path};
            my $type = $f->{type};
            _log(" - $path ($type)");
        }

        if(-e $ENV{'OMD_ROOT'}."/.THRUK_RESTART_DISABLED") {
            _log("skipped restart by .THRUK_RESTART_DISABLED file");
            next;
        }

        _log("Attempting to restart the server");

        # just kill the perl process, apache will spawn a new one
        `ps -fu \$(id -u) | grep thruk_fastcgi.pl | grep -v grep | awk \'{ print \$2 }\' | xargs -r kill`;
    }
}

############################################################
sub _check_lock {
    my $pid     = `cat $pidfile 2>/dev/null`;
    if(defined $pid and $pid =~ m/^\d+$/ and scalar kill( 0, $pid) > 0) {
        exit;
    }
    open(my $fh, '>', $pidfile);
    print $fh $$;
    close($fh);
    return 1;
}

############################################################
sub _log {
    my $text = shift;
    my $date = scalar localtime;
    print STDERR "[", $date, "] ";
    print STDERR $text, "\n";
}
