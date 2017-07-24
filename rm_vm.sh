#!/bin/bash
source functions.sh

function usage() {
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "Options:"
  echo -e "  -vm\t\t\tVM's name to be unprovisioned"
  echo -e "  -dc\t\t\tDatacenter where to VM is running"
  echo
  echo "Example: $0 -vm testvm -dc dc1"
  echo
  echo "The command above will destroy the vm named: testvm"
  echo "remove it's DNS records (A/PTR) and free it's IP in IPAM"
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
    -h) usage; exit
      ;;
    *) usage; exit 1
  esac
  shift
done

### Checks ###
#Check wether VM's name is valid
echo "$vm" |grep -E -q -v '[^a-z._A-Z0-9-]' || die "invalid name, only a-z, A-Z, 0-9, ., - and _ are allowed"
if host "$vm"."$dc".example.net bindmaster1."$dc".example.net>/dev/null; then
  die "VM doesn't exist in DNS, please manually delete VM in vCenter and in IPAM"
fi
################
clear
while true; do
    read -rp "Are you sure, you want to REMOVE $vm.$dc.example.net, which IP is $(host "$vm"."$dc".example.net|awk '{print $NF}') in $dc? (y/n) " yn
    case $yn in
        [Yy]* )
          halt_vm "$vm" "$dc"
          destroy_vm "$vm" "$dc"
          remove_dns "$vm" "$dc"
          rm_vm_ip "$vm" "$dc"
          if host "$vm"-fe."$dc".example.net bindmaster1."$dc".example.net >/dev/null; then
            remove_dns "${vm}"-fe "$dc"
            rm_vm_ip "${vm}"-fe "$dc"
          fi
          echo "$vm unprovisioned successfully"
          exit 0
          ;;
        [Nn]* )
          exit 0
          ;;
        * ) echo "Please answer yes/y or no/n.";;
    esac
done
