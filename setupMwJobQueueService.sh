#!/bin/bash

WIKIDIR=$1
WIKIID=$2

printHelp() {
	echo ""
	echo "./setupMwJobQueueService.sh /path/to/wiki/dir wiki_id"
	echo "  /path/to/wiki/dir - path to wiki web root directory"
	echo "  wiki_id - wiki identificator (any string, no spaces)"
	echo ""
}

printPrompt() {
  echo "------------------------------------------------------"
  echo "The script is going to install MediaWiki job queue service"
  echo "via systemd. The following is going to happen:"
  echo "  - job-runner executable created at /usr/local/bin/mwjobrunner"
  echo "  - log-rotation script created at /usr/local/bin/rotatelogs-compress.sh"
  echo "  - logs directory /var/log/mediawiki/ created (if not exists already)"
  echo "  - job-runner service created at /etc/systemd/system/mw-jobqueue.service"
  echo ""
  read -p "Press ENTER to continue or Ctrl+C to abort"
}

read -r -d '' SCRIPT_SERVICE <<- EOM
[Unit]
Description=MediaWiki Job runner

[Service]
Environment=MW_HOME=$WIKIDIR
Environment=MW_LOG=/var/log/mediawiki
Environment=MW_JOB_RUNNER_PAUSE=10
Environment=LOG_FILES_COMPRESS_DELAY=3600
Environment=LOG_FILES_REMOVE_OLDER_THAN_DAYS=10
Environment=WIKIID=$WIKIID
ExecStart=/usr/local/bin/mwjobrunner
Nice=20
ProtectSystem=full
User=apache
OOMScoreAdjust=200
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOM

read -r -d '' SCRIPT_JOB_RUNNER <<- EOM
#!/bin/bash

logfileName=mwjobrunner.\$WIKIID.log

echo "Starting job runner (in 60 seconds)..."
# Wait 60 seconds after the server starts up to give other processes time to get started
sleep 60
echo Job runner started.
while true; do
    for WIKI in \$MW_HOME
    do
        RJ=\$WIKI/maintenance/runJobs.php
        logFilePrev="\$logfileNow"
        logfileNow="\$MW_LOG/\$logfileName"_\$(date +%Y%m%d)
        if [ -n "\$logFilePrev" ] && [ "\$logFilePrev" != "\$logfileNow" ]; then
            /usr/local/bin/rotatelogs-compress.sh "\$logfileNow" "\$logFilePrev" &
        fi
    
        date >> "\$logfileNow"
        # Job types that need to be run ASAP mo matter how many of them are in the queue
        # Those jobs should be very "cheap" to run
        php "\$RJ" --type="enotifNotify" >> "\$logfileNow" 2>&1
        sleep 1
        php "\$RJ" --type="createPage" >> "\$logfileNow" 2>&1
        sleep 1
        php "\$RJ" --type="refreshLinks" >> "\$logfileNow" 2>&1
        sleep 1
        php "\$RJ" --type="htmlCacheUpdate" --maxjobs=500 >> "\$logfileNow" 2>&1
        sleep 1
        # Everything else, limit the number of jobs on each batch
        # The --wait parameter will pause the execution here until new jobs are added,
        # to avoid running the loop without anything to do
        php "\$RJ" --maxjobs=10 >> "\$logfileNow" 2>&1
    
        # Wait some seconds to let the CPU do other things, like handling web requests, etc
        echo mwjobrunner waits for "\$MW_JOB_RUNNER_PAUSE" seconds... >> "\$logfileNow"
        sleep "\$MW_JOB_RUNNER_PAUSE"
    done
done
EOM

read -r -d '' SCRIPT_COMPRESS_LOGS <<- EOM
#!/bin/bash

# Returns common prefix of two strings
common_prefix() {
  local n=0
  while [[ "\${1:n:1}" == "\${2:n:1}" ]]; do
    ((n++))
  done
  echo "\${1:0:n}"
}

new_log_file="\${1}"
file_to_compress="\${2}"
if [ -n "\$new_log_file" ] && [ -n "\$file_to_compress" ] && [ "\$new_log_file" != "\$file_to_compress" ]; then
    new_log_file_basename=\$(basename "\$new_log_file")
    file_to_compress_basename=\$(basename "\$file_to_compress")
    commonFilePrefix=\$(common_prefix "\$new_log_file_basename" "\$file_to_compress_basename" | sed 's/[0-9]*$//')
fi
compress_exit_code=0

if [[ "\${file_to_compress}" ]]; then
    # wait random number of seconds before compressing to avoid to compress log files simultaneously (especially for wiki farms)
    if [ "\$LOG_FILES_COMPRESS_DELAY" -eq 0 ]; then
        DELAY=0
    else
        DELAY=\$RANDOM
        ((DELAY %= "\$LOG_FILES_COMPRESS_DELAY"))
    fi
    echo "Wait for \$DELAY seconds before compressing \${file_to_compress}"
    sleep "\$DELAY"

    if [[ -f  "\${file_to_compress}" ]]; then
        echo "Compressing \${file_to_compress} ..."
        tar --gzip --create --remove-files --absolute-names --transform 's/.*\///g' --file "\${file_to_compress}.tar.gz" "\${file_to_compress}"

        compress_exit_code=\${?}

        if [[ \${compress_exit_code} == 0 ]]; then
            echo "File \${file_to_compress} was compressed."
        else
            echo "Error compressing file \${file_to_compress} (tar exit code: \${compress_exit_code})."
        fi
    else
        echo "File \${file_to_compress} does not exist".
    fi

    # remove old log files
    if [ -n "\$LOG_FILES_REMOVE_OLDER_THAN_DAYS" ] && [ "\$LOG_FILES_REMOVE_OLDER_THAN_DAYS" != false ]; then
        LOG_DIRECTORY=\$(dirname "\${file_to_compress}")
        find "\$LOG_DIRECTORY" -type f -mtime "+\$LOG_FILES_REMOVE_OLDER_THAN_DAYS" -iname "\$commonFilePrefix*" ! -iname ".*" ! -iname "*.current" -exec rm -f {} \;
    fi

    # compress uncompressed old log files
    find "\$LOG_DIRECTORY" -type f -mtime "+2" -iname "\$commonFilePrefix*" ! -iname ".*" ! -iname "*.current" ! -iname "*.gz" ! -iname "*.zip" -exec tar --gzip --create --remove-files --absolute-names --transform 's/.*\///g' --file {}.tar.gz {} \;
fi

exit \${compress_exit_code}
EOM

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if [ -z "$1" ]; then
  echo "ERROR: Please supply target wiki root path as first argument!"
  printHelp
  exit 1
fi

if [ -z "$2" ]; then
  echo "ERROR: Please supply wiki ID as second argument!"
  printHelp
  exit 1
fi

if [ ! -d "$WIKIDIR" ]; then
  echo "ERROR: Directory $WIKIDIR does not exists."
  exit 1
fi

# Check if the root directory provided is actual wiki root
# Skip this step for a silent installation!
if [ ! -f "$WIKIDIR/LocalSettings.php" ]; then
  echo "ERROR: Specified directory is not a wiki root."
  exit 1
fi

echo "- Creating /usr/local/bin/mwjobrunner .."
echo "$SCRIPT_JOB_RUNNER" > /usr/local/bin/mwjobrunner
chmod +x /usr/local/bin/mwjobrunner

echo "- Creating /etc/systemd/system/mw-jobqueue-$WIKIID.service .."
echo "$SCRIPT_SERVICE" > /etc/systemd/system/mw-jobqueue-$WIKIID.service

echo "- Creating /usr/local/bin/rotatelogs-compress.sh .."
echo "$SCRIPT_COMPRESS_LOGS" > /usr/local/bin/rotatelogs-compress.sh
chmod +x /usr/local/bin/rotatelogs-compress.sh

echo "- Creating /var/log/mediawiki/"
mkdir -p /var/log/mediawiki/
chgrp apache /var/log/mediawiki/

echo "- Enabling service .."
systemctl enable mw-jobqueue-$WIKIID
echo "- Starting service .."
service mw-jobqueue-$WIKIID start

sleep 1

echo "- Checking status .."
service mw-jobqueue-$WIKIID status

echo "Done!"


