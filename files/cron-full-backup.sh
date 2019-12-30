#!/bin/bash

set -e

HEADER="name                          last_modified        wal_segment_backup_start"
HEADER_OK=0
TO_DELETE=0
TO_KEEP=0
PGDATA=/var/lib/pgsql/12/data

if [ $# -ne 2 ]; then
  echo "Usage $0 <env file path> <retention in days>"
  exit 1
else
  source $1
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export WALE_S3_PREFIX
  export AWS_ENDPOINT
  export AWS_S3_FORCE_PATH_STYLE
  export AWS_REGION
  RETENTION_DAYS=$2
fi

# Check if this is the master
IS_SLAVE=$(su postgres -c 'psql -d postgres -t -A -c "SELECT pg_is_in_recovery();"' 2>/dev/NULL)
if [[ $IS_SLAVE != 'f' ]]; then
 echo "Running on slave, so no basebackup"
 exit 0
fi

# Run basebackup
export PGHOST=/var/run/postgresql
sudo -E -u postgres wal-g backup-push $PGDATA

# Compute target date, retention in days can have decimal part: 14.9
RETENTION_SECONDS=$(echo $RETENTION_DAYS | awk '{printf "%d",3600*24*$1}')
NOW=$(date +%s)
DELETE_BEFORE_DATE_SECOND=$(( $NOW - $RETENTION_SECONDS ))
DELETE_BEFORE_DATE=$(date -d @${DELETE_BEFORE_DATE_SECOND} -u +%Y-%m-%dT%H:%M:%SZ)
echo "Will delete backups before $DELETE_BEFORE_DATE"

# Fetch full backup list
FULL_BACKUPS=$(wal-g backup-list)
if [ $? -ne 0 ]; then
  exit 1
fi

while read line; do

  # Search for the list header
  if [ "$line" = "$HEADER" ]; then
    HEADER_OK=1
    echo "Header found"
    continue
  fi

  # Check if we are after the header
  if [ $HEADER_OK -ne 1 ]; then
    echo "Invalid format"
    exit 2
  fi

  # Extract metadata of full backup
  BACKUP_NAME=$(echo $line | cut -f 1 -d ' ')
  BACKUP_DATE=$(echo $line | cut -f 2 -d ' ')

  # Compare with argument
  if [[ $BACKUP_DATE < $DELETE_BEFORE_DATE ]]; then
    echo "Will delete $line"
    LAST_BACKUP_TO_DELETE=$BACKUP_NAME
    TO_DELETE=$(( $TO_DELETE + 1 ))
  else
    TO_KEEP=$(( $TO_KEEP + 1 ))
  fi

done < <(wal-g backup-list)

echo "Will delete $TO_DELETE and keep $TO_KEEP full backups"
if [ -n "$LAST_BACKUP_TO_DELETE" ]; then

  # Delete backups outside retention period
  echo "Should run wal-g delete before FIND_FULL $LAST_BACKUP_TO_DELETE"
  if [ $TO_KEEP -eq 0 ]; then
    echo "Something went wrong, it seems that this script try to delete all backups. Aborting"
    exit 3
  fi
  wal-g delete before FIND_FULL $LAST_BACKUP_TO_DELETE

  # Notify prometheus exporter
  PROMETHEUS_EXPORTER_PID=$(ps aux | grep wal-g-prometheus-exporter | grep -v grep | awk '{print $2}' | xargs | awk '{print $1}')
  echo "Notify prometheus exporter with PID $PROMETHEUS_EXPORTER_PID"
  kill -HUP $PROMETHEUS_EXPORTER_PID

else
  echo "No backup to delete"
fi
