#!/bin/bash

#remove crappy logo
cp -f /boot/packages/240px-Solid_black.svg /usr/local/emhttp/webGui/images/UN-logotype-gradient.svg

#remove crapy my servers plugin
mv /usr/local/emhttp/plugins/dynamix/include/DefaultPageLayout.php /usr/local/emhttp/plugins/dynamix/include/DefaultPageLayout.php.old
cp -f /boot/packages/DefaultPageLayout.php /usr/local/emhttp/plugins/dynamix/include/DefaultPageLayout.php
mv /usr/local/emhttp/plugins/dynamix.my.servers /usr/local/emhttp/plugins/dynamix.my.servers.old

#modprobe nf_conntrack

#modprobe amd_pstate shared_mem=1

upgradepkg --install-new /boot/packages/*.tgz
upgradepkg --install-new /boot/packages/*.txz

udevadm control --reload-rules && udevadm trigger &

modprobe vendor_reset

#Change reset_method for installed AMD VGA adapters for Kernel 5.15+
#https://github.com/gnif/vendor-reset/issues/46#issuecomment-992282166
TARGET_V="5.14.99"
COMPARE="$(uname -r | cut -d '-' -f1)
$TARGET_V"
if [ "$TARGET_V" != "$(echo "$COMPARE" | sort -V | tail -1)" ]; then
  while read -r line
  do
    echo 'device_specific' > $(find /sys/bus/pci/devices/* -name "*$line")/reset_method
  done <<< "$(lspci -nn | grep -E "VGA compatible controller|Display controller" | grep -E "AMD|ATI|Advanced Micro Devices" | awk '{print $1}')"
fi

sysctl -p /boot/config/sysctl.conf

# cp -f "/boot/packages/powertop" "/usr/sbin/powertop"
# chmod +x "/usr/sbin/powertop"

for cpu in /sys/devices/system/cpu/cpu*/cpufreq; do
  echo balance_performance > "$cpu"/energy_performance_preference;
done

powertop --auto-tune

# for i in /sys/class/scsi_host/host*/link_power_management_policy; do
#   echo "max_performance" > $i
# done

# for i in /sys/block/sd*/device/power/control; do
# 	echo "on" > $i
# done

# ssds="sda sdb sdf sdg sdh sde sdc sdp"
# except_LPMP="sdh"
# for f in $ssds; do
# 	echo "Processing SSD $f"
# 	###dont spindown ssds
# 	echo "0" > "/sys/block/$f/queue/rotational"
# 	###change scheduler for ssds
# 	#echo "kyber" > "/sys/block/$f/queue/scheduler"
# 	###no PM for ssds
# 	echo "on" > "/sys/block/$f/device/power/control"
# done

#old

# for i in /sys/class/scsi_host/host*/; do
# 	if [ ! -z "$except_LPMP" ] && [ -d $i/device/target*/*/block/$except_LPMP ]; then
# 	echo "max_performance exception for $except_LPMP"
# 	echo "max_performance" > "$i/link_power_management_policy"

# 	echo "disable link_power_management_policy for $except_LPMP"
# 	echo "on" > "/sys/block/$except_LPMP/device/power/control"
# 	fi
# done

#sleep 30
# for i in /dev/sd? ; do
# 		echo 180 > /sys/block/${i/\/dev\/}/device/timeout
# 		blockdev --setra 1024 $i
# done
# for i in /dev/md* ; do
#     blockdev --setra 1024 $i
# done

#gpu stuff
#sleep 5
#echo low > /sys/class/drm/card0/device/power_dpm_force_performance_level
#echo low > /sys/class/drm/card1/device/power_dpm_force_performance_level
chmod -R 0777 "/dev/dri/"

