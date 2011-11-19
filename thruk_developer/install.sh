#!/bin/bash

if [ -z $1 ]; then
    echo "usage: $0 <path to thruk git clone directory>";
    exit 1;
fi
THRUK=$1

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
sed -e 's|###DAEMON###|$OMD_ROOT/local/bin/thruk_restarter.pl|g' -i ~/etc/init.d/thruk_restarter
ln -s ../init.d/thruk_restarter ~/etc/rc.d/20-thruk_restarter

cp $BASE/thruk_restarter.pl ~/local/bin
chmod 755 ~/local/bin/thruk_restarter.pl
sed -e "s|###THRUK###|$THRUK|g" -i ~/local/bin/thruk_restarter.pl


# install thruk git version
rm -f ~/etc/thruk/themes-enabled/*
for theme in $(ls -1 $THRUK/themes/themes-enabled/); do
    ln -s $THRUK/themes/themes-enabled/$theme ~/etc/thruk/themes-enabled/
done
rm -f ~/etc/thruk/plugins-enabled/*
for theme in $(ls -1 $THRUK/plugins/plugins-enabled/); do
    ln -s $THRUK/plugins/plugins-enabled/$theme ~/etc/thruk/plugins-enabled/
done

sed -e "s|/omd/sites/$OMD_SITE/share/thruk|$THRUK|g" \
    -i ~/etc/thruk/apache.conf

echo "installation finished"

