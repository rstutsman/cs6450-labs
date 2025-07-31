#/bin/bash

#host=$(hostname -s)
host=$HOST_HOSTNAME

case "$host"
in
    node1|node2|node3)
        echo "${host} is acting as a server."
        ./server -port 8080 > ${host}-server.log 2>&1 &
        ;;
    node0)
        echo "${host} is acting as a client."
        ./server -host node1 -port 8080 > ${host}-client.log 2>&1 &
        ;;
    *)
        echo "${host} is not configured to run a specific role."
        ;;
esac
