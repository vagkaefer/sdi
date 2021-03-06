#!/bin/bash

PREFIX=$(dirname $0)

if [ ! -e $PREFIX'/sdi.conf' ]; then
    echo "ERROR: The $PREFIX/sdi.conf  file does not exist or can not be accessed"
    exit 1
fi

source $PREFIX'/sdi.conf'

#test if config is loaded
if test $? != 0; then
    echo "ERROR: failed to load $PREFIX/sdi.conf file (launchsditunnel.sh)"
    exit 1
elif ! source $PREFIX/misc.sh; then
    echo "ERROR: failed to load $PREFIX/misc.sh file (launchsditunnel.sh)"
    exit 1
elif ! source $PREFIX/parser.sh; then
    echo "ERROR: failed to load $PREFIX/parser.sh file (launchsditunnel.sh)"
    exit 1
elif ! source $PREFIX/sendfile.sh; then
    echo "WARNING: failed to load $PREFIX/sendfile.sh file"
    echo "WARNING: you will not be able to send files to hosts through SDI"
fi

# daemon must be set like this
${DAEMON:=false}

# Check if must use the fast data dir
if test "$USEFASTDATADIR" = "yes"; then
    DATADIR="$FASTDATADIR"
fi

# define STATEDIR
STATEDIR=$WWWDIR/states

usage()
{
    echo "Usage:"
    echo "  $0 [options] host1 [host2 [host3 [host... ]]]"
    echo "Options:"
    echo "  --kill=HOST      Close the SDI tunnel for HOST"
    echo "  --killall        Close all SDI tunnels and stop SDI application"
    echo "  --reload-po      Force a reload of parser objects file"
    echo "  --reload-states  Force a reload of states files"
}

removecronconfig()
{
    crontab -l | grep -v "launchscripts.sh" | crontab -
    crontab -l | grep -v "sdictl --sync-data" | crontab -
}

configurecron()
{
    # first the basic scripts proccess
    script=$(realpath launchscripts.sh)
    cron="* * * * * $script minutely"
    cron="$cron\n0 * * * * $script hourly"
    cron="$cron\n0 0 * * * $script daily"
    cron="$cron\n0 0 1 * * $script montly"
    cron="$cron\n0 0 * * 0 $script weekly"

    # check if we must add the data sync
    if test "$USEFASTDATADIR" = "yes"; then
        script=$(realpath sdictl)
        cron="$cron\n20 */$DATASYNCINTERVAL * * * $script --sync-data"
    fi

    # add old cron info
    cron="$cron\n$(crontab -l| \
                 egrep -v '(sdictl --sync-data|launchscripts.sh)'| uniq)"
    cron="$cron\n"

    # update the crontab
    printf "$cron" | crontab -
}

# function used to kill the childs of a process
killchilds()
{
    PID=$1
    CHILDS=$(ps --ppid $PID |awk 'NR>1{print $1}')
    if test -d /proc/$PID; then
        kill $PID
    fi
    for CHILD in $CHILDS; do
        killchilds $CHILD
    done
}

waitend()
{
    iter=0
    for pid in $*; do
        if ps --ppid $pid 2> /dev/null | grep -q "sleep"; then
            killchilds $pid
        fi
        while test -d /proc/$pid; do
            if test $iter -ge $KILLTOUT; then
                printf "Forced kill signal on pid $pid\n"
                kill $pid
                break
            else
                iter=$((iter+1))
            fi
            sleep 1
        done
    done
}

notunnelisopen()
{
    for pid in $(find $PIDDIRHOSTS -type f -exec cat {} \; 2> /dev/null); do
        test -d /proc/$pid && return 1
    done
    return 0
}

closesdiprocs()
{
    printf "Removing cron configuration... "
    removecronconfig
    printf "done\n"
    printf "Waiting savestate to finish... "
    PIDFIFO=$(cat $PIDDIRSYS/statesdaemon.pid)
    closefifo $PIDFIFO "states.fifo"
    printf "done\n"
    printf "Stopping SDI services... "
    kill $(cat $PIDDIRSYS/*) &> /dev/null
    printf "done\n"
}

closehost()
{
    local HOST=$1
    if test -f $PIDDIRHOSTS/$HOST.sditunnel; then
        touch $TMPDIR/${HOST}_FINISH
        echo 'killchilds $$' >> $CMDDIR/$HOST
        echo "exit 0" >> $CMDDIR/$HOST
        sleep 15
        echo "exit 0" >> $CMDDIR/$HOST
        printf "Waiting $HOST tunnel finish... "
        waitend $(cat $PIDDIRHOSTS/$HOST.sditunnel)
        printf "done\n"
        printf "Blocking $HOST to receive files... "
        sendfile -b $HOST
        printf "done\n"
        if notunnelisopen; then
            printf "There are no more SDI tunnels open. "
            printf "SDI will be closed now.\n"
            closesdiprocs
        fi
    else
        printf "Host $HOST not running.\n"
    fi
}

closeallhosts()
{
    printf "Waiting tunnels to finish... "
    touch $TMPDIR/SDIFINISH
    echo 'killchilds $$' >> $CMDGENERAL
    echo "exit 0" >> $CMDGENERAL
    sleep 15
    echo "exit 0" >> $CMDGENERAL
    waitend $(find $PIDDIRHOSTS -type f -exec cat {} \; 2> /dev/null)
    printf "done\n"
    closesdiprocs
}

SDITUNNEL()
{
    HOST=$1
    SENDCMD=$2
    RECEIVECMD=$3
    CMDFILE=$CMDDIR/$HOST

    SELF=/proc/self/task/*
    basename $SELF > $PIDDIRHOSTS/$HOST.sditunnel
    SELF=$(cat $PIDDIRHOSTS/$HOST.sditunnel)

    . "$SENDDIR/$SENDCMD"
    . "$RECEIVEDIR/$RECEIVECMD"

    while true; do
        rm -f $CMDFILE
        touch $CMDFILE
        (printf "STATUS+OFFLINE\n";
        (cat $HOOKS/onconnect.d/* 2>/dev/null;
         tail -fq -n0 $CMDFILE $CMDGENERAL &\
         echo $! > $PIDDIRHOSTS/$HOST.tail)| sdisend $HOST;
        printf "STATUS+OFFLINE\n") | sdireceive $HOST | PARSE $HOST
        #$PREFIX/socketclient $SOCKETPORT "release"
        kill $(cat $PIDDIRHOSTS/$HOST.tail) 2> /dev/null &&
        rm -f $PIDDIRHOSTS/$HOST.tail
        (test -f $TMPDIR/SDIFINISH || test -f $TMPDIR/${HOST}_FINISH) && break
        RANDOM=$(date +%N)
        sleep $(echo "($RANDOM%600)+120" | bc)
    done
    rm -f $PIDDIRHOSTS/$HOST.sditunnel
}

LAUNCH ()
{
    #If there are SDI tunnels opened, the execution should be stopped
    unset HOSTSRUNNING
    unset HOSTSTOOPEN

    for HOST in $*; do
        if test -f $PIDDIRHOSTS/$HOST.sditunnel; then
            PID=$(cat $PIDDIRHOSTS/$HOST.sditunnel)
            if test -d /proc/$PID; then
                HOSTSRUNNING="$HOSTSRUNNING $HOST"
            else
                HOSTSTOOPEN="$HOSTSTOOPEN $HOST"
            fi
        else
            HOSTSTOOPEN="$HOSTSTOOPEN $HOST"
        fi
    done
    if ! test -z "$HOSTSRUNNING"; then
        printf "\tSome SDI tunnels are already opened. Ignoring them.\n"
        printf "\tOpened hosts:$HOSTSRUNNING\n"
        if ! test -z "$HOSTSTOOPEN"; then
            printf "\nThe following tunnels will be opened now.\n"
        fi
    fi

    rm -f $TMPDIR/*FINISH

    # Create file that will be used to send commands to all hosts
    touch $CMDGENERAL

    #Open a tunnel for each host
    for HOST in $HOSTSTOOPEN; do
        echo $HOST

        SENDCMD=$(awk -F':' '$1 ~ /^'$HOST'$/ {print $2}'\
        $CLASSESDIR/$CLASS)
        test -z "$SENDCMD" && SENDCMD="$DEFAULTSEND"

        RECEIVECMD=$(awk -F':' '$1 ~ /^'$HOST'$/ {print $3}'\
        $CLASSESDIR/$CLASS)
        test -z "$RECEIVECMD" && RECEIVECMD="$DEFAULTRECEIVE"

        SDITUNNEL $HOST $SENDCMD $RECEIVECMD &

        sleep $LAUNCHDELAY
    done
}

if test $# -eq 0 ; then
    usage
    exit 1
fi



case $1 in
    --kill=?*)
        closehost $(echo $1| cut -d'=' -f2)
        exit 0
        ;;
    --killall)
        closeallhosts
        
        if $DOCKER_REGISTRY = 'true'; then
            printf "Finalizando Docker Registry..."
            docker stop registry
            printf "Done...\n"
        fi
        exit 0
        ;;
    --reload-po)
        printf "Sending signal to parsers... "
        for PARSERPID in $(cat $PIDDIRSYS/*.parserpid); do
            kill -USR1 $PARSERPID 2> /dev/null
        done
        printf "done\nParser objects will be reloaded.\n"
        exit 0
        ;;
    --reload-states)
        printf "Sending signal to states... "
        kill -USR1 $(cat $PIDDIRSYS/statesdaemon.pid) 2> /dev/null
        printf "done\nStates files will be reloaded.\n"
        exit 0
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    -*)
        echo "Unknown option."
        usage
        exit 1
        ;;
esac

#Create directories
for dir in $TMPDIR $PIDDIR $PIDDIRHOSTS $PIDDIRSYS $CMDDIR $DATADIR \
           $STATEDIR $HOOKS $SHOOKS $FIFODIR; do
    SDIMKDIR $dir || exit 1
done

#Start launching SDI tunnels
LAUNCH $*

#Initiate crontab
configurecron

if test $DAEMON = true; then
    exit 0
else
    printf "Waiting SDI Tunnels to finish"
    wait $(jobs -p)
    printf ".\n"
    exit 0
fi
