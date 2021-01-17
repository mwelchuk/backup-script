#!/bin/bash

# This script creates a rolling backup of the selected directories.
#
# Run as cron task early in the morning, will create backup for previous day.
# This script creates a rolling 7 day backup, a rolling 12 month backup and
# permanent yearly backups.

# Copyright (C) 2013  Martyn Welch <martyn@welchs.me.uk>
# 
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details.
# 
# You should have received a copy of the GNU General Public License along with
# this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.


# Ensure $PATH isn't set - it won't be there when run from cron.
unset PATH

# System commands
CP=/bin/cp
DU=/usr/bin/du
ECHO=/bin/echo
MOUNT=/bin/mount
RM=/bin/rm
RSYNC=/usr/bin/rsync
TOUCH=/bin/touch
DATE=/bin/date
MKDIR=/bin/mkdir

# Backup device
MOUNT_DEVICE=/dev/md0
MOUNT_POINT=/srv/backup

# Locations to backup
#BACKUP_LOCATIONS=("/home" "/srv/photos" "/var/lib/mythtv/pictures" "/var/lib/lxc/athena/rootfs/var/lib/dokuwiki")
BACKUP_LOCATIONS=("zeus.home:/home" "zeus.home:/srv/media/pictures" "zeus.home:/var/lib/lxc/athena/rootfs/var/lib/dokuwiki")

RETVAL=0

# Make sure we're running as root
if [[ $LOGNAME != "root" ]]
then
	$ECHO "ERROR: Must be run as root."
	exit 1
fi


# Attempt to remount the RW mount point as RW; else abort
$MOUNT -o remount,rw $MOUNT_DEVICE $MOUNT_POINT
if (( $? ))
then
	$ECHO "ERROR: Failed to remount backup directory for read/write: $MOUNT_POINT"
	exit 1
fi

DAY=$($DATE +%d)
MONTH=$($DATE +%m)
YEAR=$($DATE +%Y)

YESTERDAY=$($DATE --date="${YEAR}-${MONTH}-${DAY} -1day" +%Y-%m-%d)
PREV_DAY=$($DATE --date="${YESTERDAY} -1day" +%Y-%m-%d)

REACH=31

# Daily snapshots - taken at time when script run
if [ ! -d $MOUNT_POINT/${YESTERDAY} ]
then
	# Find the last backup
	LOOP=0
	while [ ! -d $MOUNT_POINT/${PREV_DAY} ] && [ $LOOP -lt $REACH ]
	do
		#$ECHO "${PREV_DAY} doesn't exist"
		PREV_DAY=$($DATE --date="${PREV_DAY} -1day" +%Y-%m-%d)
		let LOOP=$LOOP+1
	done

	if [ -d $MOUNT_POINT/${PREV_DAY} ]
	then
		$ECHO "Found backup from ${PREV_DAY}. Starting from hard copy."

		$CP -al $MOUNT_POINT/${PREV_DAY} $MOUNT_POINT/${YESTERDAY}
		if [ "$?" != "0" ]
		then
			$ECHO "ERROR: Failed to create copy to: $YESTERDAY"
			RETVAL=1
		fi
	else
		$ECHO "Previous backup from the last ${REACH} days not found. Starting fresh backup."

		$MKDIR $MOUNT_POINT/${YESTERDAY}
		if [ "$?" != "0" ]
		then
			$ECHO "ERROR: Failed to create directory: $YESTERDAY"
			RETVAL=1
		fi
	fi

	# Iterate through backup locations
	for item in ${!BACKUP_LOCATIONS[*]}
	do
		DIR=${BACKUP_LOCATIONS[item]}
		NAME=${DIR##*/}
		SERVER=${DIR%%:*}

		if [ ! -d $MOUNT_POINT/${YESTERDAY}/${SERVER} ]
		then
			$MKDIR $MOUNT_POINT/${YESTERDAY}/${SERVER}
			if [ "$?" != "0" ]
			then
				$ECHO "ERROR: Failed to create directory: ${SERVER}"
				RETVAL=1
			fi
		fi

		if [ ! -d $MOUNT_POINT/${YESTERDAY}/${SERVER}/${NAME} ]
		then
			$MKDIR $MOUNT_POINT/${YESTERDAY}/${SERVER}/${NAME}
			if [ "$?" != "0" ]
			then
				$ECHO "ERROR: Failed to create directory: ${NAME}"
				RETVAL=1
			fi
		fi

		# Rsync from the system into the latest snapshot
		# rsync behaves like cp --remove-destination by default
		# so the destination is unlinked first.
		$RSYNC -vaz -e ssh --delete --delete-excluded $DIR $MOUNT_POINT/${YESTERDAY}/$SERVER/$NAME
		if [ "$?" != "0" ]
		then
			$ECHO "ERROR: Failed to update: $DIR"
			RETVAL=1
		fi

	done
fi


# Yearly snapshots - taken on the first day of the year as possible
# (for the previous year)
PREV_YEAR=$((${YEAR} - 1))
if [ ! -d $MOUNT_POINT/${PREV_YEAR} ]
then
	$ECHO "Attempting to create yearly backup: "
	$CP -al $MOUNT_POINT/${YEAR}-01-01 $MOUNT_POINT/${PREV_YEAR}
	if [ "$?" != "0" ]
	then
		$ECHO "ERROR: Failed to create yearly backup"
		RETVAL=1
	fi

fi


# Monthly snapshots - taken on the first day of the month as possible
# (for the previous month)
PREV_MONTH=$($DATE --date="${YEAR}-${MONTH}-15 -1month" +%Y-%m)
if [ ! -d $MOUNT_POINT/${PREV_MONTH} ]
then
	$ECHO "Attempting to create monthly backup"
	LAST_DAY=$($DATE --date="${YEAR}-${MONTH}-01 -1day" +%Y-%m-%d)
	$CP -al $MOUNT_POINT/${LAST_DAY} $MOUNT_POINT/${PREV_MONTH}
	if [ "$?" != "0" ]
	then
		$ECHO "ERROR: Failed to create monthly backup"
		RETVAL=1
	fi
fi

# Only keep 12 months worth of monthly backups
MONTH_ROLLOUT=$($DATE --date="${YESTERDAY} -13month" +%Y-%m)
if [ -d $MOUNT_POINT/${MONTH_ROLLOUT} ]
then
	$ECHO "Deleting oldest monthly backup (keep rolling 12 months)"
	$RM -Rf $MOUNT_POINT/${MONTH_ROLLOUT}
	if [ "$?" != "0" ]
	then
		$ECHO "ERROR: Failed to delete oldest month"
		RETVAL=1
	fi
fi


# Only keep 1 weeks worth of daily backups
LOOP=0
while [ $LOOP -lt $REACH ]
do
	let OFFSET=$LOOP+7
	PREV_WEEK=$($DATE --date="${YESTERDAY} -${OFFSET}days" +%Y-%m-%d)

	if [ -d $MOUNT_POINT/${PREV_WEEK} ]
	then
		$ECHO "Deleting old daily backup (keep rolling 7 days): ${PREV_WEEK}"
		$RM -Rf $MOUNT_POINT/${PREV_WEEK}
		if [ "$?" != "0" ]
		then
			$ECHO "ERROR: Failed to delete old daily backup: ${PREV_WEEK}"
			RETVAL=1
		fi
	fi

	let LOOP=$LOOP+1
done

# Now remount the RW snapshot mountpoint as readonly
$MOUNT -o remount,ro $MOUNT_DEVICE $MOUNT_POINT
if (( $? ))
then
	$ECHO "ERROR: Failed to remount backup directory readonly: $MOUNT_POINT"
	RETVAL=1
fi

# Print summary of backup disk usage
$DU -sh  $MOUNT_POINT/*
if (( $? ))
then
	$ECHO "ERROR: Unable to profile disk usage of backup directory: $MOUNT_POINT"
	RETVAL=1
fi

exit $RETVAL
