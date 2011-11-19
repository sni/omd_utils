#!/bin/sh

### BEGIN INIT INFO
# Provides:          thruk_restarter
# Required-Start:    $local_fs
# Required-Stop:     $local_fs
# Should-Start:
# Should-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: restart thruk fcgid on changes
### END INIT INFO

cd $OMD_ROOT

. ~/.profile

DAEMON=###DAEMON###
NAME=thruk_restarter
PIDFILE=$OMD_ROOT/tmp/run/thruk_restarter.lock

case "$1" in
    start)
        echo -n "Starting $NAME..."
        mkdir -p $OMD_ROOT/tmp/run
        $DAEMON >> var/log/thruk_restarter.log 2>&1 &
        if [ $? -eq 0 ]; then
            echo "OK"
        else
            echo "failed"
        fi
        ;;
    stop)
        echo -n "Stopping $NAME..."
        pid=`cat $PIDFILE 2>/dev/null`
        if [ -z $pid ]; then
            echo ". Not running."
        else
            kill $pid
            for x in 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5; do
                echo -n "."
                ps -p $pid > /dev/null 2>&1 && sleep 1;
            done
            ps -p $pid > /dev/null 2>&1;
            if [ $? -ne 0 ]; then
                echo "OK"
                exit 0;
            else
                echo "failed"
                exit 1;
            fi
        fi
        ;;
    status)
        pid=`cat $PIDFILE 2>/dev/null`
        if [ "$pid" != "" ]; then
            ps -p $pid > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo "$NAME is running with pid $pid"
                exit 0;
            fi
        fi
        echo "$NAME is not running"
        exit 1;
    ;;
    restart)
        $0 stop && sleep 1 && $0 start
        exit $?
        ;;
    *)
        echo "Usage: $NAME {start|stop|status|restart}"
        exit 1
        ;;
esac

exit 0
