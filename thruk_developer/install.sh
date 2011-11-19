#!/bin/bash

if [ -z $1 ]; then
    echo "usage: $0 <path to thruk git clone directory>";
    exit 1;
fi

if [ -z $OMD_ROOT ]; then
    echo "Thruk Restart can only be used with OMD";
    exit 1;
fi

# check perl modules
for mod in File::ChangeNotify File::Spec; do
    perl -M$mod -e 'exit' >/dev/null 2>&1 || {
       echo "please install perl module $mod first";
       exit 1;
    }
done

BASE=`realpath $(dirname $0)`;

# install thruk restarter
rm -f ~/etc/init.d/thruk_restarter ~/etc/rc.d/20-thruk_restarter
cp $BASE/thruk_restarter_rc.sh ~/etc/init.d/thruk_restarter
chmod 755 ~/etc/init.d/thruk_restarter
sed -e "s|###DAEMON###|$BASE/thruk_restarter.pl|g" -i ~/etc/init.d/thruk_restarter
ln -s ../init.d/thruk_restarter ~/etc/rc.d/20-thruk_restarter


echo "installation finished"

