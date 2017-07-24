#!/bin/bash

template="ub_tmpl.vmdk"
source functions.sh

function usage() {
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "Options:"
  echo -e "  -vm\t\t\tNew VM's name"
  echo -e "  -dc\t\t\tDatacenter where to place the VM"
  echo -e "  -cpu\t\t\tNumber of CPUs (optional, only specify if greater, than 1 CPU)"
  echo -e "  -mem\t\t\tSize of memory in MBs (optional, only specify if greater, than 1024 MB)"
  echo -e "  -disk\t\t\tSize of the VMs disk in GBs (optional, only specify if greater, than 16GB)"
  echo -e "  -fe_net\t\tAdds frontend network to the VM"
  echo -e "  -clustered\t\tVM is clustered, eg.: don't create it on the same hypervisor as before"
  echo -e "  \t\t\t(The script will automatically look for VMNAME1 and if it finds it, it'll exclude it's hypervisor from the list of hypervisors"
  echo -e "  \t\t\tIt continues to search for VMNAME2, if the script cannot find it, the script will choose a suitable hypervisor and create VMNAME2)"
  echo -e "  \t\t\tThe script also automatically trims the ID number from the end of the VMname you specified."
  echo -e "  \t\t\tE.g.: you specify rabbitmq1, script will use rabbitmq"
  echo -e "  -recreate\t\tRecreate the VM and skip DNS registration (use for recreating already existing SDC VMs)"
  echo -e "  -nopuppet\t\tDon't install puppet on this VM (Will install puppet by default)"
  echo
  echo "Example: $0 -vm testvm -dc dc1 -cpu 2 -mem 2048 -fe_net"
  echo
  echo "The command above will create a vm named testvm (testvm.dc1.example.net)"
  echo "in RDG with 2 CPUs, 2GB memory with 16GB disk and with frontend interface"
  echo
}

if [ $# -eq 0 ]; then
  usage
  exit 2
fi

while [ "$1" != "" ]; do
  case $1 in
    -vm) shift; vm=$1
    ;;
    -dc) shift; dc=$1
      ;;
    -cpu) shift; cpu=$1
      ;;
    -mem) shift; mem=$1
      ;;
    -disk) shift; disk=$1
      ;;
    -fe_net) fe_net=1;
      ;;
    -clustered) clustered=1;
      ;;
    -recreate) recreate=1;
      ;;
    -nopuppet) nopuppet=1;
      ;;
    -h) usage; exit
      ;;
    *) usage; exit 1
  esac
  shift
done

### Checks ###
#Check wether VM's name is valid
echo "$vm" | grep -Eqv '[^a-z._A-Z0-9-]' || die "invalid name, only a-z, A-Z, 0-9, ., - and _ are allowed"
if [ -n "$clustered" ]; then
  vm=${$vms//[0-9]*$/}
fi

#Select hypervisor host
if [ -z "$clustered" ]; then
  hyp_host=$(sel_hyp "$dc")
else
  id_hyp=$(sel_hyp "$dc" "$vm")
  nodeid=$(echo "$id_hyp"|cut -f1 -d\ )
  hyp_host=$(echo "$id_hyp"|cut -f2 -d\ )
  vm=${vm}${nodeid}
fi
#Check if VM's address exists or it's frontend address, but only if it's not a recreated VM
if [ -z "$recreate" ]; then
  if host "$vm"."$dc".example.net bindmaster1."$dc".example.net>/dev/null; then
    die "VM already exists (A record is registered)!"
  fi
  if [ -n "$fe_net" ]; then
    if host "$vm"-fe."$dc".example.net bindmaster1."$dc".example.net >/dev/null; then
      die "VM-fe already exists (A record is registered)!"
    fi
  fi
fi
#Check if ubuntu template exists on the hypervisor host
check_template "$dc" "$hyp_host"
if [ -z "$cpu" ]; then
  cpu=1
else
  check_cpu "$cpu"
fi
if [ -z "$mem" ]; then
  mem=1024
else
  check_mem "$mem"
fi
if [ -n "$disk" ]; then
  check_disk "$disk"
fi
################

#Get IP for the VM (if fe_net specified get an IP for that interface as well)
ip=$(req_vm_ip "$vm" "$dc")
if [ -n "$fe_net" ]; then
  ip_fe=$(req_fe_ip "$vm" "$dc")
fi

#Register DNS records, but only if it's not a recreated VM
if [ -z "$recreate" ]; then
  register_dns "$ip" "$dc" "$vm"
  if [ -n "$fe_net" ]; then
    register_dns "${ip_fe}" "$dc" "${vm}"-fe
  fi
fi

#Create the VM and boot if no extra disk is required
if [ -z "$disk" ]; then
  create_vm "$vm" "$dc" "$cpu" "$mem" "$hyp_host" boot
  echo "Sleeping 10 sec to let VM boot"
  sleep 10
else
  create_vm "$vm" "$dc" "$cpu" "$mem" "$hyp_host"
fi

#Add extra disk space to the VM
if [ -n "$disk" ]; then
  add_disk "$vm" "$dc" "$disk" "$hyp_host"
  boot_vm "$vm" "$dc"
fi

#Generate eth0 for vmnet (and eth1 interface files for frontend) interface to the VM
file_eth0=$(gen_eth0_int "$ip" "$dc")
if [ -n "$fe_net" ]; then
  file_eth1=$(gen_eth1_int "$ip_fe" "$dc")
  add_fe_net "$vm" "$dc"
fi

#Upload interface configuration files
upload_eth0 "$vm" "$dc" "$file_eth0" && rm "$file_eth0"
if [ -n "$file_eth1" ]; then
  upload_eth1 "$vm" "$dc" "$file_eth1" && rm "$file_eth1"
fi
upload_hostname "$vm" "$dc" "$ip" >/dev/null
if [ -z "$recreate" ]; then
  ifup "$vm" "$dc" eth0 >/dev/null
  if [ -n "$fe_net" ]; then
    ifup "$vm" "$dc" eth1 >/dev/null
  fi
fi

#Install puppet agent
if [ -z "$nopuppet" ]; then
  echo "Installing puppet"
  install_puppet "$vm" "$dc"
else
  echo "Skipping puppet installation"
fi

if [ -z "$recreate" ]; then
  echo "$vm has been created on $hyp_host with IP of $ip"
else
  echo "$vm has been created on $hyp_host with IP of $ip"
  echo "After you've configured the VM don't forget to repoint it's hostname to the new ip: $ip"
fi
