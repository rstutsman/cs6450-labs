USERNAME=stutsman
EXPERIMENT=rs
PROJECT=utah-cs6450-PG0
DOMAIN=utah.cloudlab.us
NODES=2
DOCKER_IMAGE=kvs:latest

SSH_OPTIONS="-o StrictHostKeyChecking=no"

export USERNAME EXPERIMENT PROJECT DOMAIN NODES

function cl_hostname() {
    local node_id=$1
    echo "node${node_id}.${EXPERIMENT}.${PROJECT}.${DOMAIN}"
}

function cl_ssh() {
    local node_id=$1
    shift
    ssh ${SSH_OPTIONS} "${USERNAME}@$(cl_hostname $node_id)" "$@"
}

function cl_scp() {
    local node_id=$1
    shift
    scp ${SSH_OPTIONS} "$@" "${USERNAME}@$(cl_hostname $node_id):$@"
}

function cl_all() {
    local cmd="$1"
    for node_id in $(seq 0 $(($NODES-1))); do
        cl_ssh $node_id "$cmd"
    done
}

function cl_scp_all() {
    local src="$1"
    local dest="$2"
    for node_id in $(seq 0 $(($NODES-1))); do
        cl_scp $node_id "$src" "$dest"
    done
}

function cl_install_all() {
    make install.tar.gz
    cl_scp_all "install.tar.gz" "/tmp/install.tar.gz"
    cl_all "tar -xzf /tmp/install.tar.gz -C /tmp && cd /tmp/install && ./install.sh"
}

function cl_setup_nfs_server() {
    cl_ssh 0 "sudo apt-get update && sudo apt-get install -y nfs-kernel-server"
    cl_ssh 0 "sudo mkdir -p /srv/nfs/kvs"
    cl_ssh 0 "sudo chown nobody:nogroup /srv/nfs/kvs && sudo chmod 777 /srv/nfs/kvs"
    cl_ssh 0 "grep kvs /etc/exports || echo '/srv/nfs/kvs *(rw,sync,no_subtree_check)' | sudo tee -a /etc/exports"
    cl_ssh 0 "sudo exportfs -a"
}

function cl_setup_nfs_client() {
    cl_all "sudo apt-get update && sudo apt-get install -y nfs-common"
    cl_all "sudo mkdir -p /mnt/kvs"
    cl_all "sudo mount -t nfs $(cl_hostname 0):/srv/nfs/kvs /mnt/kvs" 
}

#function install_to_all() {
#    local fn="$1"
#    if [[ ! -f "$fn" ]]; then
#        echo "Requested image file $fn does not exist"
#        return 1
#    fi
#    for node_id in $(seq 0 $(($NODES-1))); do
#        scp "$fn" "${USERNAME}@$(hostname $node_id):/tmp/$fn" 
#        do_ssh $node_id "gunzip -c /tmp/$fn | docker load"
#    done
#}
#
#function run_all() {
#    for node_id in $(seq 0 $(($NODES-1))); do
#        do_ssh $node_id "docker run --network host -e HOST_HOSTNAME=\$(hostname -s) -d --rm ${DOCKER_IMAGE}"
#    done
#}
#
#function stop_all() {
#    for node_id in $(seq 0 $(($NODES-1))); do
#        #ssh "${USERNAME}@$(hostname $node_id)" "docker stop ${DOCKER_IMAGE}"
#        #### a bit tricky - need to get container IDs
#    done
#}
#
#function install_docker() {
#    on_all "sudo apt-get update && sudo apt-get install -y docker.io && sudo usermod -aG docker $USERNAME"
#}

