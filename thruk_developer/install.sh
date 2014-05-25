#!/bin/bash

function realpath {
    local path="${1:-.}"
    local back="$PWD"
    if [ -d "$path" ]; then
        cd "$path"
        /bin/pwd
        cd "$back"
        return 0
    fi
    local link ls tries=0 
    while [ -h "$path" ]; do
        ls=$(ls -ld "$path")
        link=$(expr "$ls" : '.*-> \(.*\)$')
        if expr >/dev/null "$link" : '/.*' 
        then path="$link"
        else path=$(dirname "$path")/"$link"
        fi
        tries=$((tries + 1))
        [ "$tries" -gt 100 ] && break
    done
    if [ ! -e "$path" ]; then
        echo "realpath error: $path does not exist"
        return 1
    fi
    link=$(basename "$path")
    path=$(dirname "$path") 
    cd "$path"
    echo "$(/bin/pwd)"/"$link"
    cd "$back"
}


if [ -z $1 ]; then
    echo "usage: $0 <path to thruk git clone directory>";
    exit 1;
fi
THRUK=$1

if [ -z $OMD_ROOT ]; then
    echo "Thruk Developer is intented for OMD only";
    exit 1;
fi

if [ ! -s $THRUK/lib/Thruk.pm ]; then
    echo "Thruk folder $THRUK is not a valid.";
    exit 1;
fi

echo ""
echo ""
echo "STOP! this command is supposed to run in development sites only"
echo "it cannot be undone and will break normal OMD updates."
echo "This site cannot be used for anything except thruk afterwards."
echo ""
echo -n "continue? [y|N] > "
read -a key -n 1
echo ""
if [ "$key" != 'y' ]; then
    echo "canceled"
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

mv etc/thruk/usercontent etc/thruk/usercontent.orig
ln -s ~/local/share/Thruk/root/thruk/usercontent etc/thruk/usercontent

sed -e "s|/omd/sites/$OMD_SITE/share/thruk|$THRUK|g" \
    -i ~/etc/thruk/apache.conf \
    -i ~/etc/thruk/fcgid_env.sh

sed -e 's/^exec/export PERL5LIB="$PERL5LIB:$OMD_ROOT\/share\/thruk\/lib\/";\nexec/' \
    -i ~/etc/thruk/fcgid_env.sh

touch $THRUK/.author

omd reload apache

echo "installation finished"

