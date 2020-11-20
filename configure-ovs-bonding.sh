#!/bin/bash
set -eux
# Create file to signal that ovs-configuration has executed (we are booted into 4.6)
# This is necessary because systemd calls from SDN containers are unreliable, so need to look for a file

# Configures NIC bonding and put them onto OVS bridge "br-ex"

NM_CONN_PATH="/etc/NetworkManager/system-connections"
iface=""
counter=0
# find default interface
while [ $counter -lt 12 ]; do
  # check ipv4
  iface=$(ip route show default | awk '{if ($4 == "dev") print $5; exit}')
  if [[ -n "$iface" ]]; then
    echo "IPv4 Default gateway interface found: ${iface}"
    break
  fi
  # check ipv6
  iface=$(ip -6 route show default | awk '{if ($4 == "dev") print $5; exit}')
  if [[ -n "$iface" ]]; then
    echo "IPv6 Default gateway interface found: ${iface}"
    break
  fi
  counter=$((counter+1))
  echo "No default route found on attempt: ${counter}"
  sleep 5
done

if [ "$iface" = "br-ex" ]; then
  echo "Networking already configured and up for br-ex!"
  exit 0
fi

if [ -z "$iface" ]; then
  echo "ERROR: Unable to find default gateway interface"
  exit 1
fi

# find the MAC from OVS config or the default interface to use for OVS internal port
# this prevents us from getting a different DHCP lease and dropping connection
if ! iface_mac=$(<"/sys/class/net/${iface}/address"); then
  echo "Unable to determine default interface MAC"
  exit 1
fi

echo "MAC address found for iface: ${iface}: ${iface_mac}"

# find MTU from original iface
iface_mtu=$(ip link show "$iface" | awk '{print $5; exit}')
if [[ -z "$iface_mtu" ]]; then
  echo "Unable to determine default interface MTU, defaulting to 1500"
  iface_mtu=1500
else
  echo "MTU found for iface: ${iface}: ${iface_mtu}"
fi

# create bridge
if ! nmcli connection show br-ex &> /dev/null; then
  nmcli c add type ovs-bridge conn.interface br-ex con-name br-ex 802-3-ethernet.mtu ${iface_mtu} 802-3-ethernet.cloned-mac-address ${iface_mac}
fi

# store old conn for later
old_conn=$(nmcli --fields UUID,DEVICE conn show --active | grep ${iface} | awk '{print $1}')

bond_iface="bond0"
# find default port to add to bridge
if ! nmcli connection show ovs-port-phys0 &> /dev/null; then
  nmcli c add type ovs-port conn.interface ${bond_iface} master br-ex con-name ovs-port-phys0
fi

if ! nmcli connection show ovs-port-br-ex &> /dev/null; then
  nmcli c add type ovs-port conn.interface br-ex master br-ex con-name ovs-port-br-ex
fi

if ! nmcli connection show ovs-if-phys0 &> /dev/null; then
  nmcli c add type bond conn.interface ${bond_iface} master ovs-port-phys0 con-name ovs-if-phys0 \
    connection.autoconnect-priority 100 connection.autoconnect-slaves 1 802-3-ethernet.mtu ${iface_mtu} bond.options mode=active-backup
fi

# bring down any old iface
nmcli device disconnect $iface

if ! nmcli connection show ${bond_iface}-port0 &> /dev/null; then
  nmcli c add type 802-3-ethernet conn.interface ${iface} master ${bond_iface} con-name ${bond_iface}-port0 connection.slave-type bond 802-3-ethernet.mtu ${iface_mtu}
fi

nmcli conn up ovs-if-phys0

if ! nmcli connection show ovs-if-br-ex &> /dev/null; then
  if nmcli --fields ipv4.method,ipv6.method conn show $old_conn | grep manual; then
    echo "Static IP addressing detected on default gateway connection: ${old_conn}"
    # find and copy the old connection to get the address settings
    if egrep -l --include=*.nmconnection $old_conn ${NM_CONN_PATH}/*; then
      old_conn_file=$(egrep -l --include=*.nmconnection $old_conn ${NM_CONN_PATH}/*)
      cloned=false
    else
      echo "WARN: unable to find NM configuration file for conn: ${old_conn}. Attempting to clone conn"
      old_conn_file=${NM_CONN_PATH}/${old_conn}-clone.nmconnection
      nmcli conn clone ${old_conn} ${old_conn}-clone
      cloned=true
      if [ ! -f "$old_conn_file" ]; then
        echo "ERROR: unable to locate cloned conn file: ${old_conn_file}"
        exit 1
      fi
      echo "Successfully cloned conn to ${old_conn_file}"
    fi
    echo "old connection file found at: ${old_conn_file}"
    new_conn_file=${NM_CONN_PATH}/ovs-if-br-ex.nmconnection
    if [ -f "$new_conn_file" ]; then
      echo "WARN: existing br-ex interface file found: $new_conn_file, which is not loaded in NetworkManager...overwriting"
    fi
    cp -f ${old_conn_file} ${new_conn_file}
    if $cloned; then
      nmcli conn delete ${old_conn}-clone
      rm -f ${old_conn_file}
    fi
    ovs_port_conn=$(nmcli --fields connection.uuid conn show ovs-port-br-ex | awk '{print $2}')
    br_iface_uuid=$(cat /proc/sys/kernel/random/uuid)
    # modify file to work with OVS and have unique settings
    sed -i '/^\[connection\]$/,/^\[/ s/^uuid=.*$/uuid='"$br_iface_uuid"'/' ${new_conn_file}
    sed -i '/^multi-connect=.*$/d' ${new_conn_file}
    sed -i '/^\[connection\]$/,/^\[/ s/^type=.*$/type=ovs-interface/' ${new_conn_file}
    sed -i '/^\[connection\]$/,/^\[/ s/^id=.*$/id=ovs-if-br-ex/' ${new_conn_file}
    sed -i '/^\[connection\]$/a slave-type=ovs-port' ${new_conn_file}
    sed -i '/^\[connection\]$/a master='"$ovs_port_conn" ${new_conn_file}
    if grep 'interface-name=' ${new_conn_file} &> /dev/null; then
      sed -i '/^\[connection\]$/,/^\[/ s/^interface-name=.*$/interface-name=br-ex/' ${new_conn_file}
    else
      sed -i '/^\[connection\]$/a interface-name=br-ex' ${new_conn_file}
    fi
    if ! grep 'cloned-mac-address=' ${new_conn_file} &> /dev/null; then
      sed -i '/^\[ethernet\]$/,/^\[/ s/^cloned-mac-address=.*$/cloned-mac-address='"$iface_mac"'/' ${new_conn_file}
    else
      sed -i '/^\[ethernet\]$/a cloned-mac-address='"$iface_mac" ${new_conn_file}
    fi
    if grep 'mtu=' ${new_conn_file} &> /dev/null; then
      sed -i '/^\[ethernet\]$/,/^\[/ s/^mtu=.*$/mtu='"$iface_mtu"'/' ${new_conn_file}
    else
      sed -i '/^\[ethernet\]$/a mtu='"$iface_mtu" ${new_conn_file}
    fi
    cat <<EOF >> ${new_conn_file}
[ovs-interface]
type=internal
EOF
    nmcli c load ${new_conn_file}
    echo "Loaded new ovs-if-br-ex connection file: ${new_conn_file}"
  else
    nmcli c add type ovs-interface slave-type ovs-port conn.interface br-ex master ovs-port-br-ex con-name \
      ovs-if-br-ex 802-3-ethernet.mtu ${iface_mtu} 802-3-ethernet.cloned-mac-address ${iface_mac}
  fi
fi

# wait for DHCP to finish, verify connection is up
counter=0
while [ $counter -lt 5 ]; do
  sleep 5
  # check if connection is active
  if nmcli --fields GENERAL.STATE conn show ovs-if-br-ex | grep -i "activated"; then
    echo "OVS successfully configured"
    ip a show br-ex
    exit 0
  fi
  counter=$((counter+1))
done

echo "WARN: OVS did not succesfully activate NM connection. Attempting to bring up connections"
counter=0
while [ $counter -lt 5 ]; do
  if nmcli conn up ovs-if-br-ex; then
    echo "OVS successfully configured"
    ip a show br-ex
    configure_driver_options ${iface}
    exit 0
  fi
  sleep 5
  counter=$((counter+1))
done

echo "ERROR: Failed to activate ovs-if-br-ex NM connection"
# if we made it here networking isnt coming up, revert for debugging
set +e
nmcli conn down ovs-if-br-ex
nmcli conn down ovs-if-phys0
nmcli conn up $old_conn
exit 1
