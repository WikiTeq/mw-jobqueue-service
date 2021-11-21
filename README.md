# Mediawiki Job Queue Service

The tool automates configuration of MediaWiki runJobs.php maitnenace script runs
as a system service on CentOS and Ubuntu OS.

The script setups the following:

* Creates universal `/usr/local/bin/mwjobrunner` to execute runJobs.php
* Creates `/etc/systemd/system/mw-jobqueue-<WIKI_ID>.service` for each wiki
* Stores logs at `/var/log/mediawiki/mwjobrunner.<WIKI_ID>.log`
* Creates `/usr/local/bin/rotatelogs-compress.sh` helper script to rotate logs

It's safe to run this script multiple times, once per each wiki you want the service
to be created for.

# Usage:

* Clone the repo
* Run `./setupMwJobQueueService.sh /path/to/wiki/dir wiki_id` where the first argument is the absolute path to the wiki root and the second argument is the wiki id to be used for service and log files (can be any string without spaces)

