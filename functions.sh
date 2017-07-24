#!/bin/bash
function die() {
  echo "$*"
  exit 1
}

function check_template() {
  local dc="$1"
  local host="$2"
  local ds
  ds="$(echo "$host"|cut -f1 -d.)_data"
  echo "Checking if template exists on $host"
  govc datastore.ls -dc "$dc" -ds "$ds" |grep -qw "$template" || die "Ubuntu template doesn't exist on $host:$ds"
  echo "Template exists on $host"
}

function check_cpu() {
  local cpu="$1"
  echo "Checking if $cpu is valid"
  echo "$cpu" | grep -E -q -v '[^0-9]' || die "invalid cpu number"
  if [ "$cpu" -lt 1 ] || [ "$cpu" -gt 24 ]; then
    die "Invalid cpu number. Specify the CPU count between 1 and 24."
  fi
  echo "$cpu is valid"
}

function check_mem() {
  local mem="$1"
  echo "Checking if $mem is valid"
  echo "$mem" | grep -E -q -v '[^0-9]' || die "invalid mem size"
  if [ "$mem" -lt 1024 ] || [ "$mem" -gt 131072 ]; then
    die "Invalid memory size. Specify the size of the memory between 1024 and 131072 MBs"
  fi
  echo "$mem is valid"
}

function check_disk() {
  local disk="$1"
  echo "Checking if $disk is valid"
  echo "$disk" | grep -E -q -v '[^0-9]' || die "invalid disk size"
  if [ "$disk" -lt 16 ]; then
    die "The size of the disk cannot be less than 16 in GBs"
  fi
  echo "$disk is valid"
}

function random6() {
  if [ "$(uname)" == "Darwin" ]; then
    openssl rand -base64 6
  else
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 6 | head -n 1
  fi
}

function req_vm_ip() {
  local vm="$1"
  local dc="$2"
  case "$dc" in
    hsk)
      local iprange="10.250.132.0"
      ;;
    rdg)
      local iprange="10.252.132.0"
      ;;
    pp)
      local iprange="10.251.132.0"
      ;;
    devhsk)
      local iprange="10.100.132.0"
      ;;
    *)
      die "Invalid datacenter $dc"
      ;;
  esac

  curl -s "http://ipam.$dc.example.net/api/getFreeIP.php?apiapp=provisioner&apitoken=e36394ace6f303d0723b2c7ac58a6af7&subnet=$iprange&host=$vm.$dc.example.net"
}

function rm_vm_ip() {
  local vm="$1"
  local dc="$2"
  curl -s "http://ipam.$dc.example.net/api/removeHost.php?apiapp=provisioner&apitoken=e36394ace6f303d0723b2c7ac58a6af7&host=$vm.$dc.example.net"
}

function req_fe_ip() {
  local vm="$1"
  local dc="$2"
  case "$dc" in
    hsk)
      local iprange="10.250.200.0"
      ;;
    rdg)
      local iprange="10.252.200.0"
      ;;
    pp)
      local iprange="10.251.188.0"
      ;;
    devhsk)
      local iprange="N/A"
      ;;
    *)
      die "Invalid datacenter $dc"
      ;;
  esac

  curl -s "http://ipam.$dc.example.net/api/getFreeIP.php?apiapp=provisioner&apitoken=e36394ace6f303d0723b2c7ac58a6af7&subnet=$iprange&host=$vm-fe.$dc.example.net"
}

function gen_eth0_int() {
  local filename
  filename="/tmp/tmp_$(random6).int"
  local ip="$1"
  local dc="$2"
  local netmask gateway dns1 dns2
  case "$dc" in
    hsk)
      netmask="255.255.252.0"
      gateway="10.250.132.1"
      dns1="10.250.135.201"
      dns2="10.250.135.202"
      ;;
    rdg)
      netmask="255.255.252.0"
      gateway="10.252.132.1"
      dns1="10.252.135.201"
      dns2="10.252.135.202"
      ;;
    pp)
      netmask="255.255.252.0"
      gateway="10.251.132.1"
      dns1="10.251.135.201"
      dns2="10.251.135.202"
      ;;
    devhsk)
      netmask="255.255.252.0"
      gateway="10.100.132.1"
      dns1="10.100.135.10"
      dns2="10.100.135.11"
      ;;
    *)
      die "Invalid datacenter $dc"
      ;;
  esac

  echo "auto eth0" > "$filename"
  echo "iface eth0 inet static" >> "$filename"
  echo -e "\taddress $ip" >> "$filename"
  echo -e "\tnetmask $netmask" >> "$filename"
  echo -e "\tgateway $gateway" >> "$filename"
  echo -e "\tdns-search $dc.example.net" >> "$filename"
  echo -e "\tdns-nameservers $dns1 $dns2" >> "$filename"

  echo "$filename"
}

function gen_eth1_int() {
  local filename
  filename="/tmp/tmp_$(random6).int"
  local ip="$1"
  local dc="$2"
  local netmask
  case "$dc" in
    hsk|rdg|pp|devhsk)
      netmask="255.255.255.0"
      ;;
    *)
      die "Invalid datacenter $dc"
      ;;
  esac

  echo "auto eth1" > "$filename"
  echo "iface eth1 inet static" >> "$filename"
  echo -e "\taddress $ip" >> "$filename"
  echo -e "\tnetmask $netmask" >> "$filename"

  echo "$filename"
}

function generate_in-addr() {
  #generates from 1.2.3.4 -> 4.3.2.1.in-addr.arpa
  local ip=$1
  echo "$ip" | awk -F . '{print $4"."$3"."$2"."$1".in-addr.arpa"}'
}

function register_dns() {
  local a_record
  a_record="/tmp/tmp_$(random6).A"
  local ptr_record
  ptr_record="/tmp/tmp_$(random6).PTR"
  local ip="$1"
  local dc="$2"
  local vm="$3"
  local key="Kroot.example.net.+157+18170.private"
  local reverse
  reverse=$(generate_in-addr "$ip")
  case "$dc" in
    pp)
      local rev_zone
      rev_zone=$(echo "$reverse"| cut -f2- -d.)
      ;;
    rdg|hsk|devhsk)
      local rev_zone
      rev_zone=$(echo "$reverse"|cut -f3- -d.)
      ;;
  esac
  echo "Registering A and PTR records for $vm"
  #register A
  echo "server bindmaster1.$dc.example.net" > "$a_record"
  echo "zone $dc.example.net" >> "$a_record"
  echo "prereq nxdomain $vm.$dc.example.net" >> "$a_record"
  echo "update add $vm.$dc.example.net 86400 a $ip" >> "$a_record"
  echo "send" >> "$a_record"


  if nsupdate -k $key -v "$a_record"; then
    die "Cannot register A record, please check..."
  fi
  rm "$a_record"

  #register PTR
  echo "server bindmaster1.$dc.example.net" > "$ptr_record"
  echo "zone $rev_zone" >> "$ptr_record"
  echo "update add $(generate_in-addr "$ip") 86400 ptr $vm.$dc.example.net." >> "$ptr_record"
  echo "send" >> "$ptr_record"


  if nsupdate -k $key -v "$ptr_record"; then
    die "Cannot register PTR record, please check..."
  fi
  rm "$ptr_record"
}

function remove_dns() {
  local a_record
  a_record="/tmp/tmp_$(random6).dA"
  local ptr_record
  ptr_record="/tmp/tmp_$(random6).dPTR"
  local dc="$2"
  local vm="$1"
  local ip
  ip=$(host "$vm"."$dc".example.net |awk '{print $NF}')
  local key="Kroot.example.net.+157+18170.private"
  local reverse
  reverse=$(generate_in-addr "$ip")
  case "$dc" in
    pp)
      local rev_zone
      rev_zone=$(echo "$reverse"| cut -f2- -d.)
      ;;
    rdg|hsk|devhsk)
      local rev_zone
      rev_zone=$(echo "$reverse"|cut -f3- -d.)
      ;;
  esac
  echo "Removing A and PTR records for $vm"
  #deregister A
  echo "server bindmaster1.$dc.example.net" > "$a_record"
  echo "zone $dc.example.net" >> "$a_record"
  echo "update delete $vm.$dc.example.net a" >> "$a_record"
  echo "send" >> "$a_record"


  if nsupdate -k $key -v "$a_record"; then
    die "Cannot remove A record, please check..."
  fi
  rm "$a_record"

  #deregister PTR
  echo "server bindmaster1.$dc.example.net" > "$ptr_record"
  echo "zone $rev_zone" >> "$ptr_record"
  echo "update delete $(generate_in-addr "$ip") ptr" >> "$ptr_record"
  echo "send" >> "$ptr_record"

  if nsupdate -k $key -v "$ptr_record"; then
    die "Cannot remove PTR record, please check..."
  fi
  rm "$ptr_record"
}


function sel_hyp() {
  local vm="$2"
  local dc="$1"
  if [ -z "$vm" ]; then
    node index.js --dc "$dc"
  else
    node index.js --dc "$dc" --vm "$vm"
  fi
}

function create_vm() {
  local vm="$1"
  local dc="$2"
  local cpu="$3"
  local mem="$4"
  local host="$5"
  local power="$6"
  local ds
  ds="$(echo "$host"|cut -f1 -d.)_data"
  echo "Creating $vm"
  if [ -z "$power" ]; then
    govc vm.create -c "$cpu" -dc "$dc" -disk /"$template" -ds "$ds" -host "$host" -m "$mem" -net vm_net -on=false "$vm"
  else
    govc vm.create -c "$cpu" -dc "$dc" -disk /"$template" -ds "$ds" -host "$host" -m "$mem" -net vm_net "$vm"
  fi
  echo "$vm created."
}

function add_disk() {
  local vm="$1"
  local dc="$2"
  local input_size="$3"
  local host="$4"
  local ds
  ds="$(echo "$host"|cut -f1 -d.)_data"
  local name
  name=$vm-$(random6)
  local size
  size="$(echo "$input_size"-16|bc)"
  echo "Increasing disksize to $input_size"
  govc vm.disk.create -dc "$dc" -ds "$ds" -name "$name" -size "${size}"GB -vm "$vm"
  echo "Done"
}

function add_fe_net() {
  local vm=$1
  local dc=$2
  local net="frontend_net"
  echo "Adding Fronend interface to $vm"
  govc vm.network.add -dc "$dc" -net $net -vm "$vm"
  echo "Done"
}

function upload_file() {
  local vm=$1
  local dc=$2
  local src=$3
  local dst=$4
  echo "Uploading file $src to ${vm}:$dst"
  govc guest.upload -dc "$dc" -vm "$vm" -f -l root:rootpassword "$src" "$dst"
  echo "Sleeping a second"
  sleep 1
  echo "Done"
}

function upload_eth0 {
  local vm=$1
  local dc=$2
  local src=$3
  echo "Uploading VM net conf file (eth0)"
  govc guest.upload -dc "$dc" -vm "$vm" -f -l root:rootpassword "$src" /etc/network/interfaces.d/eth0
  sleep 1
  echo "Done"
}

function upload_eth1 {
  local vm=$1
  local dc=$2
  local src=$3
  echo "Uploading Frontend conf file (eth1)"
  govc guest.upload -dc "$dc" -vm "$vm" -f -l root:rootpassword "$src" /etc/network/interfaces.d/eth1
  sleep 1
  echo "Done"
}

function upload_hostname() {
  local hostname
  hostname="/tmp/tmp_$(random6).hostname"
  local hosts
  hosts="/tmp/tmp_$(random6).hosts"
  local vm=$1
  local dc=$2
  local ip=$3
  echo "Uploading hostname and hosts file and setting hostname"
  echo -e "127.0.0.1\tlocalhost" > "$hosts"
  echo -e "$ip\t$vm.$dc.example.net\t$vm" >> "$hosts"

  echo "$vm" > "$hostname"
  govc guest.upload -dc "$dc" -vm "$vm" -f -l root:rootpassword "$hostname" /etc/hostname
  govc guest.upload -dc "$dc" -vm "$vm" -f -l root:rootpassword "$hosts" /etc/hosts
  govc guest.start  -dc "$dc" -vm "$vm" -l root:rootpassword /bin/hostname "$vm"
  rm "$hostname" "$hosts"
}

function boot_vm() {
  local vm="$1"
  local dc="$2"
  govc vm.power -dc "$dc" -on "$vm"
  echo "Sleeping 10 sec to let VM boot"
  sleep 10
}

function halt_vm() {
  local vm="$1"
  local dc="$2"
  echo "Poweroffing $vm"
  govc vm.power -dc "$dc" -off=true "$vm"
}

function destroy_vm() {
  local vm="$1"
  local dc="$2"
  echo "Destroying $vm"
  govc vm.destroy -dc "$dc" "$vm"
}

function reboot_vm() {
  local vm="$1"
  local dc="$2"
  echo "Rebooting $vm"
  govc vm.power -dc "$dc" -r "$vm"
}

function ifup() {
  local vm="$1"
  local dc="$2"
  local iface="$3"
  echo "Bringing up interface $iface"
  govc guest.start -dc "$dc" -vm "$vm" -l root:rootpassword /sbin/ifup "$iface"
}

function install_puppet() {
  local vm="$1"
  local dc="$2"
  echo "Installing puppet on ${vm}"
  govc guest.start -dc "$dc" -vm "$vm" -l root:rootpassword /usr/bin/curl -k https://puppet:8140/packages/current/install.bash -o /tmp/puppetinstall.sh
  sleep 2
  govc guest.start -dc "$dc" -vm "$vm" -l root:rootpassword /bin/bash /tmp/puppetinstall.sh
}

