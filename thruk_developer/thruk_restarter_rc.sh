#!/bin/bash

### OMD INIT INFO
# PIDFILE:  tmp/run/thruk_restarter.lock
# BINARY:   ###DAEMON###
### END INIT INFO

cd || exit 1
. lib/omd/init_profile
. .profile

NAME=thruk_restarter
DAEMON=###DAEMON###
PID_FILE=tmp/run/thruk_restarter.lock
OPTS=" "
LOG_FILE=var/log/thruk_restarter.log
STORE_PID=1
NOHUP=1

__generic_init "$*"
