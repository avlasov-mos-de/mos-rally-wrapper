#!/bin/bash


set -e

message() {
    printf "\e[33m%s\e[0m\n" "${1}"
}

remote_cli() {
    ssh ${CONTROLLER_HOST} ". openrc; $@"
}

function init_vars() {
    message "Declaring vars"
    DIR_NAME="rally_home"
    RALLY_IMAGE="rallyforge/rally"
    CONTROLLER_HOST="$(fuel node "$@" | grep controller | awk -F\| '{print $5}' | tr -d ' ' | head -1)"
    REMOTE_CA_CERT="${REMOTE_CA_CERT:-/var/lib/astute/haproxy/public_haproxy.pem}"
    LOCAL_CA_CERT="${LOCAL_CA_CERT:-${USER_HOME_DIR}/public_haproxy.pem}"
    OS_PUBLIC_AUTH_URL="$(ssh ${CONTROLLER_HOST} ". openrc; keystone catalog --service identity 2>/dev/null | grep publicURL | awk '{print \$4}'")"
    OS_PUBLIC_IP="$(ssh ${CONTROLLER_HOST} "grep -w public_vip /etc/hiera/globals.yaml | awk '{print \$2}' | sed 's/\"//g'")"
    message "OS_PUBLIC_AUTH_URL = ${OS_PUBLIC_AUTH_URL}"
    message "OS_PUBLIC_IP = ${OS_PUBLIC_IP}"
    KEYSTONE_HAPROXY_CONFIG_PATH="${KEYSTONE_HAPROXY_CONFIG_PATH:-/etc/haproxy/conf.d/030-keystone-2.cfg}"

    local htts_public_endpoint="$(ssh ${CONTROLLER_HOST} ". openrc; keystone catalog --service identity 2>/dev/null | grep https")"
    if [ "${htts_public_endpoint}" ]; then
        TLS_ENABLED="yes"
        message "TLS_ENABLED = yes"
    else
        TLS_ENABLED="no"
        message "TLS_ENABLED = no"
    fi
}


function placing_files() {
    if [ -d ~/"${DIR_NAME}" ]; then
        message "Directory ~/${DIR_NAME} already exists. Exiting." &&\
        exit 1
    fi

    mkdir ~/${DIR_NAME}
    message "Putting files into container directory."
    scp ${CONTROLLER_HOST}:/root/openrc ~/${DIR_NAME}/
    cp ${PWD}/prepare_rally.sh ~/${DIR_NAME}/
    cp -r ${PWD}/templates ~/${DIR_NAME}/
    chmod +x ~/${DIR_NAME}/prepare_rally.sh
    sed -i "s|^export OS_AUTH_URL=.*$|export OS_AUTH_URL='${OS_PUBLIC_AUTH_URL}'|g" ~/${DIR_NAME}/openrc
    sed -i 's/internalURL/publicURL/g' ~/${DIR_NAME}/openrc
    echo "export OS_PUBLIC_IP=${OS_PUBLIC_IP}" >> ~/${DIR_NAME}/openrc
}

function add_public_bind_to_keystone_haproxy_conf() {
    # Keystone operations require admin endpoint which is internal and not
    # accessible from the Fuel master node. So we need to make all Keystone
    # endpoints accessible from the Fuel master node. Before we do it, we need
    # to make haproxy listen to Keystone admin port 35357 on interface with public IP
    message "Add public bind to Keystone haproxy config for admin port on all controllers"
    if [ ! "$(ssh ${CONTROLLER_HOST} "grep ${OS_PUBLIC_IP}:35357 ${KEYSTONE_HAPROXY_CONFIG_PATH}")" ]; then
        local controller_node_ips="$(fuel node "$@" | grep controller | awk -F\| '{print $5}' | tr -d ' ')"
        local bind_string="  bind ${OS_PUBLIC_IP}:35357"
        if [ "${TLS_ENABLED}" = "yes" ]; then
            bind_string="  bind ${OS_PUBLIC_IP}:35357 ssl crt ${REMOTE_CA_CERT}"
        fi
        for controller_node_ip in ${controller_node_ips}; do
            ssh ${controller_node_ip} "echo ${bind_string} >> ${KEYSTONE_HAPROXY_CONFIG_PATH}"
        done

        message "Restart haproxy"
        ssh ${CONTROLLER_HOST} "pcs resource disable p_haproxy --wait"
        ssh ${CONTROLLER_HOST} "pcs resource enable p_haproxy --wait"
    else
        message "Public bind already exists!"
    fi
}

function modify_endpoints() {
    # Keystone operations require admin endpoint which is internal and not
    # accessible from the Fuel master node. So we need to make all Keystone
    # endpoints accessible from the Fuel master node
    message "Make Keystone endpoints public"
    local identity_service_id="$(remote_cli "keystone service-list 2>/dev/null | grep identity | awk '{print \$2}'")"
    local internal_url="$(remote_cli "keystone endpoint-list 2>/dev/null | grep ${identity_service_id} | awk '{print \$8}'")"
    local admin_url="$(remote_cli "keystone endpoint-list 2>/dev/null | grep ${identity_service_id} | awk '{print \$10}'")"
    if [ "${admin_url}" = "${OS_PUBLIC_AUTH_URL/5000/35357}" ]; then
        message "Keystone endpoints already public!"
    else
        local old_endpoint="$(remote_cli "keystone endpoint-list 2>/dev/null | grep ${identity_service_id} | awk '{print \$2}'")"
        remote_cli "keystone endpoint-create --region RegionOne --service ${identity_service_id} --publicurl ${OS_PUBLIC_AUTH_URL} --adminurl ${OS_PUBLIC_AUTH_URL/5000/35357} --internalurl ${internal_url} 2>/dev/null"
        remote_cli "keystone endpoint-delete ${old_endpoint} 2>/dev/null"
    fi
}


function pull_rally_image() {
    message "--- Pulling image ----"
    docker pull ${RALLY_IMAGE}
}

function start_rally_container(){
    if [ ! "$(docker ps -a |grep rally-MOS-benchmarking)" ]; then
        message "Creating container."
        docker create -u root --name='rally-MOS-benchmarking' -t -i -v ~/${DIR_NAME}:/home/rally ${RALLY_IMAGE} bash
    fi

    message "Starting container."
    docker start rally-MOS-benchmarking
    message "You will be promted into a shell of Rally Docker container."
    message "Press any key and follow the instructions from README."
    read
    set -x
    dockerctl shell rally-MOS-benchmarking
    set +x
}

add_dns_entry_for_tls () {
    message "Adding DNS entry for TLS"
    if [ "${TLS_ENABLED}" = "yes" ]; then
        local os_tls_hostname="$(echo ${OS_PUBLIC_AUTH_URL} | sed 's/https:\/\///;s|:.*||')"
        local dns_entry="$(grep "${OS_PUBLIC_IP} ${os_tls_hostname}" /etc/hosts)"
        if [ ! "${dns_entry}" ]; then
            echo "${OS_PUBLIC_IP} ${os_tls_hostname}" >> /etc/hosts
        else
            message "DNS entry for TLS is already added!"
        fi
    else
        message "TLS is not enabled. Nothing to do"
    fi
}

function main(){
    init_vars "$@"
    add_dns_entry_for_tls
    placing_files
    add_public_bind_to_keystone_haproxy_conf "$@"
    modify_endpoints
    pull_rally_image
    start_rally_container
}

main "$@"
