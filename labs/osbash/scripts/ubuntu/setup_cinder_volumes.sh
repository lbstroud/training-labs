#!/usr/bin/env bash

set -o errexit -o nounset

TOP_DIR=$(cd "$(dirname "$0")/.." && pwd)

source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/credentials"
source "$LIB_DIR/functions.guest.sh"
source "$CONFIG_DIR/admin-openstackrc.sh"

exec_logfile

indicate_current_auto

#------------------------------------------------------------------------------
# Set up Block Storage service (cinder).
# http://docs.openstack.org/mitaka/install-guide-ubuntu/cinder-storage-install.html
#------------------------------------------------------------------------------

MY_MGMT_IP=$(get_node_ip_in_network "$(hostname)" "mgmt")
echo "IP address of this node's interface in management network: $MY_MGMT_IP."

echo "Installing qemu support package for non-raw image types."
sudo apt-get install -y qemu

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Prerequisites
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "Installing the Logical Volume Manager (LVM)."
sudo apt-get install -y lvm2

echo "Configuring LVM physical and logical volumes."

# We don't have a dedicated physical partition for cinder to use; instead,
# we configure a file-backed loopback device.
cinder_loop_path=/var/lib/cinder-volumes
cinder_loop_dev=/dev/loop2
sudo dd if=/dev/zero of=$cinder_loop_path bs=1 count=0 seek=4G
sudo losetup $cinder_loop_dev $cinder_loop_path

# Tell upstart to run losetup again when the system is rebooted
cat << UPSTART | sudo tee "/etc/init/cinder-losetup.conf"
description "Set up loop device for cinder."

start on mounted MOUNTPOINT=/
task
exec /sbin/losetup $cinder_loop_dev $cinder_loop_path
UPSTART

sudo pvcreate $cinder_loop_dev
sudo vgcreate cinder-volumes $cinder_loop_dev

# We could configure LVM to only use loopback devices or only the device
# we just set up, but scanning our block devices to find our volume group
# is fast enough.

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Install and configure Cinder Volumes
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "Installing cinder."
sudo apt-get install -y cinder-volume

conf=/etc/cinder/cinder.conf
echo "Configuring $conf."

function get_database_url {
    local db_user=$CINDER_DB_USER
    local database_host=controller

    echo "mysql+pymysql://$db_user:$CINDER_DBPASS@$database_host/cinder"
}

database_url=$(get_database_url)
cinder_admin_user=$(service_to_user_name cinder)

echo "Setting database connection: $database_url."
iniset_sudo $conf database connection "$database_url"

# Configure [DEFAULT] section.
iniset_sudo $conf DEFAULT rpc_backend rabbit

iniset_sudo $conf oslo_messaging_rabbit rabbit_host controller
iniset_sudo $conf oslo_messaging_rabbit rabbit_userid openstack
iniset_sudo $conf oslo_messaging_rabbit rabbit_password "$RABBIT_PASS"

iniset_sudo $conf DEFAULT auth_strategy keystone

# Configure [keystone_authtoken] section.
iniset_sudo $conf keystone_authtoken auth_uri http://controller:5000
iniset_sudo $conf keystone_authtoken auth_url http://controller:35357
iniset_sudo $conf keystone_authtoken auth_type password
iniset_sudo $conf keystone_authtoken project_domain_name default
iniset_sudo $conf keystone_authtoken user_domain_name default
iniset_sudo $conf keystone_authtoken project_name "$SERVICE_PROJECT_NAME"
iniset_sudo $conf keystone_authtoken username "$cinder_admin_user"
iniset_sudo $conf keystone_authtoken password "$CINDER_PASS"

iniset_sudo $conf DEFAULT my_ip "$MY_MGMT_IP"

iniset_sudo $conf lvm volume_driver cinder.volume.drivers.lvm.LVMVolumeDriver
iniset_sudo $conf lvm volume_group  cinder-volumes
iniset_sudo $conf lvm iscsi_protocol iscsi
iniset_sudo $conf lvm iscsi_helper  tgtadm

iniset_sudo $conf DEFAULT enabled_backends lvm
iniset_sudo $conf DEFAULT glance_api_servers http://controller:9292

iniset_sudo $conf oslo_concurrency lock_path /var/lib/cinder/tmp

# Finalize installation
echo "Restarting cinder service."
sudo service tgt restart
sudo service cinder-volume restart

sudo rm -f /var/lib/cinder/cinder.sqlite

#------------------------------------------------------------------------------
# Verify the Block Storage installation
# http://docs.openstack.org/mitaka/install-guide-ubuntu/cinder-verify.html
#------------------------------------------------------------------------------

echo "Verifying Block Storage installation on controller node."

echo "Sourcing the admin credentials."
AUTH="source $CONFIG_DIR/admin-openstackrc.sh"

# It takes time for Cinder to be aware of its services status.
# Force restart cinder API and wait for 20 seconds.
echo "Restarting Cinder API."
node_ssh controller "sudo service cinder-api restart"

echo -n "Waiting for cinder to start."
until node_ssh controller "$AUTH; cinder service-list" >/dev/null 2>&1; do
    echo -n .
    sleep 1
done
echo

echo "cinder service-list is available:"
node_ssh controller "$AUTH; cinder service-list"


function check_cinder_services {

    # It takes some time for cinder to detect its services and update its
    # status. This method will wait for 60 seconds to get the status of the
    # cinder services.
    local i=0
    while : ; do
        # Check service-list every 5 seconds
        if [ $(( i % 5 )) -ne 0 ]; then
            if ! node_ssh controller "$AUTH; cinder service-list" 2>&1 |
                    grep -q down; then
                echo
                echo "All cinder services seem to be up and running."
                node_ssh controller "$AUTH; cinder service-list"
                return 0
            fi
        fi
        if [[ "$i" -eq "60" ]]; then
            echo
            echo "ERROR Cinder services are not working as expected."
            node_ssh controller "$AUTH; cinder service-list"
            exit 1
        fi
        i=$((i + 1))
        echo -n .
        sleep 1
    done
}

# To avoid race conditions which were causing Cinder Volumes script to fail,
# check the status of the cinder services. Cinder takes a few seconds before it
# is aware of the exact status of its services.
echo -n "Waiting for all cinder services to start."
check_cinder_services

echo "Sourcing the demo credentials."
AUTH="source $CONFIG_DIR/demo-openstackrc.sh"

echo "openstack volume create --size 1 volume1"
node_ssh controller "$AUTH; openstack volume create --size 1 volume1"

echo -n "Waiting for cinder to list the new volume."
until node_ssh controller "$AUTH; openstack volume list| grep volume1" > /dev/null 2>&1; do
    echo -n .
    sleep 1
done
echo

function wait_for_cinder_volume {

    echo -n 'Waiting for cinder volume to become available.'
    local i=0
    while : ; do
        # Check list every 5 seconds
        if [ $(( i % 5 )) -ne 0 ]; then
            if node_ssh controller "$AUTH; openstack volume list" 2>&1 |
                    grep -q "volume1 .*|.* available"; then
                echo
                return 0
            fi
        fi
        if [ $i -eq 20 ]; then
            echo
            echo "ERROR Failed to create cinder volume."
            node_ssh controller "$AUTH; openstack volume list"
            exit 1
        fi
        i=$((i + 1))
        echo -n .
        sleep 1
    done
}

# Wait for cinder volume to be created
wait_for_cinder_volume

echo "Volume successfully created:"
node_ssh controller "$AUTH; openstack volume list"

echo "Deleting volume."
node_ssh controller "$AUTH; openstack volume delete volume1"

echo "openstack volume list"
node_ssh controller "$AUTH; openstack volume list"
