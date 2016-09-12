#!/bin/bash
# This bash script attempts to establish exclusive control over
# a subdirectory to FS_PATH.  This is done by first looking for
# a missing directory and then creating it and generating a
# lockfile.  Failing that, the next step is that it will try
# existing directories in the range of 0..NODE_COUNT, exclusive.
[ -z "$FS_PATH" ] && echo "Need to set FS_PATH" && exit 1;

APP_NAME="etcd"
LOCKFILE="$APP_NAME.lock"
AUTHORITATIVE_ID="0"

ip a

if [ ! -d "$FS_PATH" ]; then
    mkdir -p "$FS_PATH"
fi

launch_etcd() {
    local IP=$1
    local ID=$2
    local DATA_DIR=$3
    local CLUSTER_STATE=$4
    local INITIAL_CLUSTER=$5

    if [ -z "$INITIAL_CLUSTER" ]; then
        INITIAL_CLUSTER="$APP_NAME-$ID=http://$IP:2380"
    else
        INITIAL_CLUSTER="$INITIAL_CLUSTER,$APP_NAME-$ID=http://$IP:2380"
    fi

    (
        /bin/etcd --initial-cluster-token etcd-cluster -data-dir="$DATA_DIR" -initial-cluster-state $CLUSTER_STATE -listen-client-urls http://0.0.0.0:2379,http://0.0.0.0:4001 -advertise-client-urls http://$IP:2379  -listen-peer-urls http://$IP:2380,http://$IP:7001 -initial-advertise-peer-urls http://$IP:2380 -name "$APP_NAME-$ID" -initial-cluster "$INITIAL_CLUSTER"
    ) &
}

start_app() {
    if [ -z $1 ]; then
        echo "Directory must be specified."
        return 1
    elif [ -z $2 ]; then
        echo "Node ID must be specified."
        return 1
    fi

    DATADIR=$1
    ID=$2
    WORKINGDIR="$DATADIR/$ID"
    APP_DATA_DIR="$WORKINGDIR/$APP_NAME/data"

    if [ ! -d "$DATADIR" ]; then
        mkdir -p "$DATADIR"
    fi

    MY_IP=`ip -4 addr show scope global dev ethwe | grep inet | awk '{print $2}' | cut -d / -f 1`
    PEER_IPS=`drill $APP_NAME.weave.local | grep $APP_NAME | grep -v "\;\;" | awk '{print $5}' | grep -v $MY_IP`

    if [ -z "$PEER_IPS" ]; then
        if [ "$ID" -eq "$AUTHORITATIVE_ID" ]; then
            echo "Launching as master/initial node."
            ETCD_PID=""
            launch_etcd "$MY_IP" "$ID" "$APP_DATA_DIR" "new"
        else
            echo "No seed node running.  Exiting."
            sleep 180
            exit 1
        fi
    else
        #  see if peers have already formed a cluster
        CLUSTER=""
        RUNNING_PEER_IPS=""
        for peer in $PEER_IPS; do
            #  check if a member is already starting and removing them
            STARTING=`/bin/etcdctl --endpoint=http://$peer:2379 member list | grep unstarted | awk -F "[" '{print $1}'`
            for start in $STARTING
            do
              /bin/etcdctl --endpoint=http://$peer:2379 member remove $start
            done
            # attempt to see if client port is open
            nc -w 1 $peer 2379
            if [ $? -eq 0 ]; then
                NAME=`/bin/etcdctl --endpoint=http://$peer:2379 member list | grep "$peer" | awk '{print $2}' | sed s/name=//`
                if [ $? -eq 0 ]; then
                    RUNNING_PEER_IPS="$RUNNING_PEER_IPS $peer"
                    if [ ! -z "$NAME" ]; then
                        if [ -z "$CLUSTER" ]; then
                            CLUSTER="$NAME=http://$peer:2380"
                        else
                            CLUSTER="$CLUSTER,$NAME=http://$peer:2380"
                        fi
                    fi
                fi
            fi
        done

        if [ -z "$CLUSTER" ]; then
            if [ "$ID" -eq "$AUTHORITATIVE_ID" ]; then
                echo "Launching as master/initial node, despite other containers being online."
                ETCD_PID=""
                launch_etcd "$MY_IP" "$ID" "$APP_DATA_DIR" "new"
            else
                echo "No seed node running.  Exiting."
                sleep 2
                exit 1
            fi
        else
            for peer in $RUNNING_PEER_IPS; do
                nc -w 1 $peer 2379
                if [ $? -eq 1 ]; then
                    echo "A known peer went down.  Bad state.  Exiting..."
                    exit 1
                else
                    KNOWN_ID=`/bin/etcdctl --endpoint=http://$peer:2379 member list | grep etcd-$ID | awk '{print $1}' | sed 's/\://'`
                    if [ ! -z "$KNOWN_ID" ]; then
                        # remove the existing cluster node
                        echo "Removing node in the cluster.  ID: $KNOWN_ID, IP: $MY_IP"
                        /bin/etcdctl --endpoint=http://$peer:2379 member remove $KNOWN_ID
                        if [ $? -eq 1 ]; then
                            echo "Error removing member in cluster.  ID: $KNOWN_ID, IP: $MY_IP  Exiting..."
                            exit 1
                        fi
                    fi
                    # add the peer to the cluster
                    echo "Adding node to the cluster.  IP: $MY_IP"
                    /bin/etcdctl --endpoint=http://$peer:2379 member add "$APP_NAME-$ID" http://$MY_IP:2380
                    #if [ $? -eq 1 ]; then
                    #    echo "Error adding member to cluster.  IP: $MY_IP  Exiting..."
                    #    exit 1
                    #fi
                fi
                break
            done
        fi

        echo "Launching etcd into an existing cluster.  IP: $MY_IP.  Cluster: $CLUSTER"
        launch_etcd "$MY_IP" "$ID" "$APP_DATA_DIR" "existing" "$CLUSTER"
    fi

    # wait for etcd to be available
    ETCD_UP=0
    for f in {1..10}; do
        sleep 1
        nc -w 1 localhost 2379
        if [ $? -eq 0 ]; then
            ETCD_UP=1
            break
        fi
    done

    if [ "$ETCD_UP" -eq 0 ]; then
        echo "etcd did not come up...exiting..."
        exit 1
    fi

    # loop while PID exists
    while curl -s -m 5 http://localhost:2379/v2/keys > /dev/null
    do
      sleep 10
    done
    echo "Exiting."
    exit 1
}


lock_data_dir() {
    if [ -z $1 ]; then
        echo "Directory must be specified."
        return 1
    elif [ -z $2 ]; then
        echo "Node ID must be specified."
        return 1
    fi

    DATADIR=$1
    ID=$2
    WORKINGDIR="$DATADIR/$ID"
    cd $1
    if [ $? -ne 0 ]; then
        echo "Unable to change into directory $WORKINGDIR"
        return 1
    fi

    echo "Attempting to lock: $WORKINGDIR/$LOCKFILE"
    exec 200>> "$WORKINGDIR/$LOCKFILE"
    flock -n 200
    if [ $? -ne 0 ]; then
        echo "Unable to lock."
        exec 200>&-
        return 1;
    else
        date 1>&200
        echo "Lock acquired.  Starting application."
        start_app "$FS_PATH" "$ID"
    fi
}

DATADIR="$FS_PATH/$ID"
echo "Attempting $DATADIR"
if [ ! -d "$DATADIR" ]; then
    r=`mkdir "$DATADIR"`
    if [ $? -eq 0 ]; then
        lock_data_dir "$FS_PATH" "$ID"
        if [ $? -ne 0 ]; then
            echo "Error locking directory."
        fi
    else
        if [ ! -d "$DATADIR" ]; then
            echo "Unable to create directory.  System error."
            exit 1
        else
            echo "Another process already created directory."
        fi
    fi
else
    echo "Directory already taken."
fi
