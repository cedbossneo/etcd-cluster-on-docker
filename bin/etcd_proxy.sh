#!/bin/bash
# This bash script attempts to establish exclusive control over
# a subdirectory to FS_PATH.  This is done by first looking for
# a missing directory and then creating it and generating a
# lockfile.  Failing that, the next step is that it will try
# existing directories in the range of 0..NODE_COUNT, exclusive.
APP_NAME="etcd"

launch_etcd() {
    local INITIAL_CLUSTER=$1

    (
      /bin/etcd -proxy on -listen-client-urls http://0.0.0.0:2379,http://0.0.0.0:4001 -initial-cluster "$INITIAL_CLUSTER"
    ) &
}

start_app() {
    PEER_IPS=`drill $APP_NAME.weave.local | grep $APP_NAME | grep -v "\;\;" | awk '{print $5}'`
    if [ -z "$PEER_IPS" ]; then
        echo "No seed node running.  Exiting."
        sleep 180
        exit 1
    else
        #  see if peers have already formed a cluster
        CLUSTER=""
        RUNNING_PEER_IPS=""
        for peer in $PEER_IPS; do
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
            echo "No seed node running.  Exiting."
            sleep 2
            exit 1
        else
            for peer in $RUNNING_PEER_IPS; do
                nc -w 1 $peer 2379
                if [ $? -eq 1 ]; then
                    echo "A known peer went down.  Bad state.  Exiting..."
                    exit 1
                fi
                break
            done
        fi

        echo "Launching etcd as proxy into an existing cluster. Cluster: $CLUSTER"
        launch_etcd "$CLUSTER"
        sleep 10
        while true
        do
          for peer in $RUNNING_PEER_IPS; do
              nc -w 1 $peer 2379
              if [ $? -eq 1 ]; then
                  echo "A known peer went down.  Bad state.  Exiting..."
                  exit 1
              fi
              break
          done
          sleep 10
        done
        echo "Exiting."
    fi
}

start_app
