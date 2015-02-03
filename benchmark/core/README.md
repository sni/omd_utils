= Core Benchmarks

This readme is for debian 7 (wheezy), adjust the commands to the linux of your choice.

All command must be run as root and should be done on a test virtual machine, seriously.

== Preparation

Initially you have to install a recent omd-nc package:

    gpg --keyserver keys.gnupg.net --recv-keys F8C1CA08A57B9ED7
    gpg --armor --export F8C1CA08A57B9ED7 | apt-key add -
    echo 'deb http://labs.consol.de/repo/testing/debian wheezy main' >> /etc/apt/sources.list
    apt-get update
    apt-get install omd-newcores

Then create all required sites by:

    make create

== Run Tests

Simply run the tests with:

    make testall

Or run tests for a single core with:

    make TEST_SITES=naemon test

== Results

The results are stored in `/var/tmp/coreresults` as csv data. Interpretation is
left as exercise to the user. There is a index.html placed in the result folder
which creates some summary graphs.
