#!/bin/bash
apt-get install -yqq scsitools
rescan-scsi-bus
endSector=$(parted -s /dev/sda unit s p free |grep -ve '^$'|tail -1 |grep Free|awk '{print $2}')
disks=$(cat /proc/partitions |grep -v sda |grep sd|awk '{print $4}' |cut -b1-3|uniq)
if [ -n "$endSector" ]; then
  parted -s /dev/sda unit s resizepart 2 $endSector
  parted -s /dev/sda unit s resizepart 5 $endSector
  pvresize /dev/sda5
  lvextend -l +$(vgdisplay |grep -i free |awk '{print $5}') /dev/ubuntu-vg/root
  resize2fs /dev/ubuntu-vg/root
fi
if [ -n "$disks" ]; then
  for disk in $disks; do
    mount |grep -q ${disk}1
    if [ $? -ne 0 ]; then
      test -b /dev/${disk}1 || (parted -s /dev/$disk mklabel gpt && parted -s /dev/$disk unit s mkpart primary 2048 100%)
      pvs |grep -q /dev/${disk}1 || pvcreate /dev/${disk}1
      vgdisplay -v |grep -q /dev/${disk}1 || vgextend ubuntu-vg /dev/${disk}1
      if [ $(vgdisplay |grep Free |awk '{print $5}') -ne 0 ]; then
        lvextend -l +$(vgdisplay |grep -i free |awk '{print $5}') /dev/ubuntu-vg/root
        resize2fs /dev/ubuntu-vg/root
      fi
    fi
  done
fi
