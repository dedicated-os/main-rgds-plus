#!/bin/sh

DEV_PATH=/dev/mmcblk2p1
TF2_PATH=/mnt/sdcard

mount -t vfat -o rw,utf8,noatime,nodiratime $DEV_PATH $TF2_PATH

exec $TF2_PATH/main.sh