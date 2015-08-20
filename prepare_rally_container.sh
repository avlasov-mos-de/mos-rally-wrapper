#!/bin/bash


set -e

function init_vars() {
echo "Declaring vars"

DIR_NAME="rally_home"
RALLY_IMAGE="rallyforge/rally"
cntrl_ip=`fuel nodes |grep controller |head -n 1| awk -F\| '{print $5}'| sed -e 's/ //g' | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}"`

keystone_srv_id=`ssh root@${cntrl_ip} "source openrc; keystone service-list" |grep keystone|awk '{print $2}'`
endpoint_id=`ssh root@${cntrl_ip} "source openrc; keystone endpoint-list" |grep ${keystone_srv_id}|awk '{print $2}'`
publ_url=`ssh root@${cntrl_ip} "source openrc; keystone endpoint-list" |grep ${endpoint_id}|awk '{print $6}'`
priv_url=`ssh root@${cntrl_ip} "source openrc; keystone endpoint-list" |grep ${endpoint_id}|awk '{print $8}'`


admin_url=`ssh root@${cntrl_ip} "source openrc; keystone endpoint-list"|grep ${endpoint_id}|awk '{print $10}'`


os_region=`ssh root@${cntrl_ip} "cat openrc |grep OS_REGION_NAME|cut -d \' -f 2" `

OS_AUTH_URL_P="$(ssh ${cntrl_ip} ". openrc; keystone catalog --service identity 2>/dev/null | grep publicURL | awk '{print \$4}'")"
OS_AUTH_IP_P="$(echo "${OS_AUTH_URL_P}" | grep -Eo '([0-9]{1,3}[\.]){3}[0-9]{1,3}')"
KEYSTONE_HAPROXY_CONFIG_PATH="${KEYSTONE_HAPROXY_CONFIG_PATH:-/etc/haproxy/conf.d/030-keystone-2.cfg}"

}


function placing_files() {

if [ -d ~/"${DIR_NAME}" ]; then
  echo "Directory ~/${DIR_NAME} already exists. Although content should not be overwritten you may want to move files to another place or delete this directory"
  echo "Continue to work with existing directory?"
  select yn in "Yes" "No"; do
    case $yn in
        Yes )
              break
              ;;
        No )  echo "Good buy. Please take your time to make desicion"
              exit -1

    esac
  done
else
  echo "Ceating directory which will be mounted inside container"
  mkdir ~/${DIR_NAME}

fi

echo "Getting openrc and placing it inside contaiers dir"
scp root@${cntrl_ip}:/root/openrc ~/${DIR_NAME}/
cp ${PWD}/prepare_rally.sh ~/${DIR_NAME}/
cp -r ${PWD}/templates ~/${DIR_NAME}/
chmod +x ~/${DIR_NAME}/prepare_rally.sh

sed -i "s|^export OS_AUTH_URL=.*$|export OS_AUTH_URL='${publ_url}'|g" ~/${DIR_NAME}/openrc
sed -i 's/internalURL/publicURL/g' ~/${DIR_NAME}/openrc
}

function add_public_bind_to_keystone_haproxy_conf() {
    # Keystone operations require admin endpoint which is internal and not
    # accessible from the Fuel master node. So we need to make all Keystone
    # endpoints accessible from the Fuel master node. Before we do it, we need
    # to make haproxy listen to Keystone admin port 35357 on interface with public IP
    echo "Add public bind to Keystone haproxy config for admin port on all controllers"
    if [ ! "$(ssh ${cntrl_ip} "grep ${OS_AUTH_IP_P}:35357 ${KEYSTONE_HAPROXY_CONFIG_PATH}")" ]; then
        local controller_node_ids=$(fuel node "$@" | grep controller | awk '{print $1}')
        for controller_node_id in ${controller_node_ids}; do
            ssh node-${controller_node_id} "echo '  bind ${OS_AUTH_IP_P}:35357' >> ${KEYSTONE_HAPROXY_CONFIG_PATH}"
        done

        echo "Restart haproxy"
        ssh ${cntrl_ip} "pcs resource disable p_haproxy --wait"
        ssh ${cntrl_ip} "pcs resource enable p_haproxy --wait"
    else
        echo "Public bind already exists!"
    fi
}

function modify_endpoints() {
    # Keystone operations require admin endpoint which is internal and not
    # accessible from the Fuel master node. So we need to make all Keystone
    # endpoints accessible from the Fuel master node
    echo "Make Keystone endpoints public"
    local identity_service_id="$(ssh ${cntrl_ip} ". openrc; keystone service-list 2>/dev/null | grep identity | awk '{print \$2}'")"
    local internal_url="$(ssh ${cntrl_ip} ". openrc; keystone endpoint-list 2>/dev/null | grep ${identity_service_id} | awk '{print \$8}'")"
    local admin_url="$(ssh ${cntrl_ip} ". openrc; keystone endpoint-list 2>/dev/null | grep ${identity_service_id} | awk '{print \$10}'")"
    if [ "${admin_url}" = "${OS_AUTH_URL_P/5000/35357}" ]; then
        echo "Keystone endpoints already public!"
    else
        local old_endpoint="$(ssh ${cntrl_ip} ". openrc; keystone endpoint-list 2>/dev/null | grep ${identity_service_id} | awk '{print \$2}'")"
        ssh ${cntrl_ip} ". openrc; keystone endpoint-create --region RegionOne --service ${identity_service_id} --publicurl ${OS_AUTH_URL_P} --adminurl ${OS_AUTH_URL_P/5000/35357} --internalurl ${internal_url} 2>/dev/null"
        ssh ${cntrl_ip} ". openrc; keystone endpoint-delete ${old_endpoint} 2>/dev/null"
    fi
}


function pull_rally_image() {
echo "--- Pulling image ----"
docker pull ${RALLY_IMAGE}
}

function start_rally_container(){
if [ ! "$(docker ps -a |grep rally-MOS-benchmarking)" ]; then
echo "Creating container with command 'docker create -u root --name='rally-MOS-benchmarking' -t -i -v ~/rally_home:/home/rally ${RALLY_IMAGE} bash'"
docker create -u root --name='rally-MOS-benchmarking' -t -i -v ~/rally_home:/home/rally ${RALLY_IMAGE} bash

echo "Starting container with command"
echo "docker start rally-MOS-benchmarking"
docker start rally-MOS-benchmarking

echo "If you exit container you can access it by executing following command"
echo "dockerctl shell rally-MOS-benchmarking"
dockerctl shell rally-MOS-benchmarking

else
docker start rally-MOS-benchmarking
dockerctl shell rally-MOS-benchmarking

fi
}

function main(){
init_vars
placing_files
add_public_bind_to_keystone_haproxy_conf
modify_endpoints
pull_rally_image
start_rally_container
}

main
