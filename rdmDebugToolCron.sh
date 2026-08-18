#!/bin/sh

CRONTAB_DIR="/var/spool/cron/crontabs"
CRONFILE_BK="/tmp/rdmcron.$$"

crontab -l -c ${CRONTAB_DIR} > ${CRONFILE_BK} 2>/dev/null

grep -q "rdm -e" ${CRONFILE_BK}
if [ $? -ne 0 ]; then
    echo "* * * * * /usr/bin/rdm -e >> /rdklogs/logs/rdm_status.log 2>&1" >> ${CRONFILE_BK}
    crontab ${CRONFILE_BK} -c ${CRONTAB_DIR}
fi

rm -f ${CRONFILE_BK}
