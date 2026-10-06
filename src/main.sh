#!/bin/sh

MAIN_PATH=/mnt/sdcard/main.sh
if [ -f $MAIN_PATH ]; then
	exec $MAIN_PATH
fi

