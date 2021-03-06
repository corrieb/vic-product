#!/usr/bin/env bash
# Copyright 2017 VMware, Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
set -euf -o pipefail

TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")
DIRNAME="vic_appliance_logs_$TIMESTAMP"
OUTFILE="$DIRNAME.tar.gz"
TMPDIR="/tmp/$DIRNAME"
APPLIANCE_DIR=$TMPDIR/appliance
ADMIRAL_DIR=$TMPDIR/admiral
HARBOR_DIR=$TMPDIR/harbor
VIC_MACHINE_SERVER_DIR=$TMPDIR/vic-machine-server
PSC_DIR=$TMPDIR/psc
OUTDIR="/storage/log/"

mkdir -p "$TMPDIR"
mkdir -p "$APPLIANCE_DIR"
mkdir -p "$ADMIRAL_DIR"
mkdir -p "$HARBOR_DIR"
mkdir -p "$VIC_MACHINE_SERVER_DIR"
mkdir -p "$PSC_DIR"

# commandToFile runs command $1 and writes the output to file $2 in $TMPDIR
function commandToFile {
  local OUTDIR
  local DIR="${3:-}"
  if [ -n "$DIR" ]; then
    OUTDIR="$TMPDIR/$DIR"
    mkdir -p "$OUTDIR"
  else
    OUTDIR="$TMPDIR"
  fi

  echo "Running $1"
  set +e
  $1 &> "$OUTDIR/$2"
  set -e
}

# commandToCompressed runs command $1 and writes gzipped output to file $2 in $TMPDIR
function commandToCompressed {
  local OUTDIR
  local DIR="${3:-}"
  if [ -n "$DIR" ]; then
    OUTDIR="$TMPDIR/$DIR"
    mkdir -p "$OUTDIR"
  else
    OUTDIR="$TMPDIR"
  fi

  echo "Running $1, compressing output"
  set +e
  $1 | gzip > "$OUTDIR/$2.gz"
  set -e
}

# getLog copies files with suffix to component directory in $TMPDIR
function getLog {
  local FILES
  FILES=$(find "$1" -name "$2")
  local DIR
  DIR=$(basename "$1")

  for file in $FILES; do
    commandToCompressed "cat $file" "$(basename "$file")" "$DIR"
  done
}

# getFailedLogs gets the journal for failed units
function getFailedLogs {
  echo "Getting logs for failed units"
  local UNITS
  UNITS=$(systemctl list-units --state=failed --no-legend --no-pager | cut -d ' ' -f1 | grep -E '(service|target|path|timer)') || true
  local LEN
  LEN=$(echo "$UNITS" | wc -l)
  LEN=$((LEN - 1))
  echo "Found $LEN failed units"
  if [ $LEN -eq 0 ]; then
    return
  fi
  for unit in $UNITS; do
    commandToCompressed "journalctl -u $unit --no-pager" "journal_$unit"
  done
  echo "Finished getting logs for failed units"
}

# getPrivateFiles includes files that may contain secret values
function getPrivateFiles {
  echo "Including private values in log bundle"

  commandToFile "openssl x509 -in /storage/data/certs/ca.crt -text -noout" "ca.crt" "certs"
  commandToFile "openssl x509 -in /storage/data/certs/server.cert.pem -text -noout" "server.cert.pem" "certs"
  commandToFile "cat /storage/data/certs/cert_gen_type" "cert_gen_type" "certs"
  commandToFile "cat /storage/data/certs/extfile.cnf" "extfile.cnf" "certs"

  # Admiral
  commandToFile "openssl x509 -in /storage/data/admiral/cert/ca.crt -text -noout" "ca.crt" "admiral_certs"
  commandToFile "openssl x509 -in /storage/data/admiral/cert/server.crt -text -noout" "server.crt" "admiral_certs"
  commandToFile "cat /storage/data/admiral/cert/extfile.cnf" "extfile.cnf" "admiral_certs"

  # Harbor
  commandToFile "cat /storage/data/harbor/harbor.cfg" "harbor.cfg" "harbor"
  set +e
  cp -R /etc/vmware/harbor/common/config "$HARBOR_DIR"
  set -e
}

# getDiagInfo gathers diagnostic info and logs
function getDiagInfo {
  # Appliance
  commandToFile "hostnamectl" "hostnamectl" "appliance"
  commandToFile "ip address show" "ip_addr" "appliance"
  commandToFile "ovfenv" "ovfenv" "appliance"
  commandToFile "cat /etc/vmware/environment" "environment" "appliance"
  commandToFile "cat /etc/vmware/firstboot" "firstboot" "appliance"
  commandToFile "uptime" "uptime" "appliance"
  commandToFile "cat /etc/vmware/version" "appliance_version" "appliance"
  commandToFile "cat /storage/data/version" "data_version" "appliance"
  commandToFile "systemctl status --no-pager" "systemctl_status" "appliance"
  commandToFile "systemctl list-jobs --no-pager" "systemctl_list-jobs" "appliance"
  commandToFile "systemctl list-units --state=failed --no-pager" "systemctl_failed" "appliance"
  commandToFile "iptables -L -n" "iptables" "appliance"
  commandToFile "df -h" "df" "appliance"
  commandToFile "docker ps -a" "docker_ps" "appliance"
  commandToFile "docker images" "docker_images" "appliance"

  # Services
  commandToCompressed "journalctl -u admiral_startup --no-pager" "journal_admiral_startup" "admiral"
  commandToCompressed "journalctl -u admiral --no-pager" "journal_admiral" "admiral"
  commandToCompressed "journalctl -u harbor_startup --no-pager" "journal_harbor_startup" "harbor"
  commandToCompressed "journalctl -u harbor --no-pager" "journal_harbor" "harbor"
  commandToCompressed "journalctl -u fileserver --no-pager" "journal_fileserver" "appliance"
  commandToCompressed "journalctl -u get_token --no-pager" "journal_get_token" "psc"
  commandToCompressed "journalctl -u vic_machine_server --no-pager" "journal_vic_machine_server" "vic-machine-server"

  # PSC
  commandToFile "cat /storage/data/admiral/configs/psc-config.properties" "admiral_data_psc-config" "psc"
  commandToFile "cat /etc/vmware/psc/admiral/psc-config.properties" "admiral_psc-config" "psc"
  commandToFile "du -k /etc/vmware/psc/admiral/tokens.properties" "admiral_psc-token" "psc"
  commandToFile "cat /etc/vmware/psc/engine/psc-config.properties" "engine_psc-config" "psc"
  commandToFile "du -k /etc/vmware/psc/engine/tokens.properties" "engine_psc-token" "psc"
  commandToFile "cat /etc/vmware/psc/harbor/psc-config.properties" "harbor_psc-config" "psc"
  commandToFile "du -k /etc/vmware/psc/harbor/tokens.properties" "harbor_psc-token" "psc"

  # Admiral
  commandToFile "cat /storage/data/admiral/configs/config.properties" "config.properties" "admiral"
  commandToFile "cat /storage/data/admiral/8282/serviceHostState.json" "serviceHostState.json" "admiral"

  # Harbor
  commandToFile "cat /storage/data/harbor/config/config.json" "config.json" "harbor"
  local FILES
  FILES=$(find "/etc/vmware/harbor" -maxdepth 1 -name "*.yml")
  for file in $FILES; do
    commandToFile "cat $file" "$(basename "$file")" "harbor"
  done

  # Gets the latest log for each component. Additional rotated logs must be retrieved manually.
  getLog "/storage/log/admiral" "*.log"
  getLog "/storage/log/harbor" "*.log"
  getLog "/storage/log/vic-machine-server" "*.log"

  getFailedLogs

  if [ "$INC_PRIVATE" == "true" ]; then
    getPrivateFiles
  fi
}

# compressBundle creates the log bundle tar
function compressBundle {
  set +e
  checkStorage "$OUTDIR"
  if [ $? -ne 0 ]; then
    echo "Insufficient space for output file."
    cleanup
    echo "Exiting."
    exit 1
  fi
  set -e
  local DIR
  echo "Creating log bundle $OUTDIR$OUTFILE"
  tar -czvf "$OUTDIR/$OUTFILE" -C /tmp "$DIRNAME"
  echo "--------------------"
  echo "Created log bundle $OUTDIR$OUTFILE"
  if [ "$INC_PRIVATE" == "true" ]; then
    echo "Log bundle contains files with private values"
  fi
  echo "--------------------"
}

# checkStorage checks that there is a reasonable amount of disk space left
# does not guarantee that there is enough space for the log bundle or temporary files
function checkStorage {
  local FREE
  FREE=$(df -k --output=avail "$1" | tail -n1)
  if [ "$FREE" -lt 524288 ]; then
    echo "--------------------"
    echo "Warning: less than 512MB free on $1"
    if [ "$IGNORE_DISK_SPACE" == "true" ]; then
      echo "Ignoring low free space on $1"
      echo "--------------------"
      return 0
    else
      echo "Free up space on $1 or override warning with --ignore-disk-space"
      echo "--------------------"
      return 1
    fi
  fi
  return 0
}

# cleanup removes temporary files
function cleanup {
  echo "Removing $TMPDIR"
  rm -rf "$TMPDIR"
  echo "Removed $TMPDIR"
}

function usage {
  echo "Usage:"
  echo "$0 [--include-private] [--outdir <directory>] [--ignore-disk-space]"
  echo ""
  echo "--include-private:    includes files containing private values in the log bundle"
  echo "--outdir <directory>: directory to store the resulting log bundle"
  echo "--ignore-disk-space:  ignore low disk space warnings for log bundle output"
  echo ""
}

function main {
  while [[ $# -gt 0 ]]
  do
    key="$1"

    case $key in
      -h|--help)
        usage
        exit 0
        ;;
      --include-private)
        INC_PRIVATE="true"
        echo "Including files containing private values in log bundle"
        shift # past argument
        ;;
      --ignore-disk-space)
        IGNORE_DISK_SPACE="true"
        echo "Bypassing warnings for low disk space"
        shift # past argument
        ;;
      --outdir)
        OUTDIR="$2"
        shift # past argument
        shift # past value
        ;;
      *)
        # unknown option
        echo "Unknown option"
        usage
        exit 1
        ;;
    esac
  done

  INC_PRIVATE=${INC_PRIVATE:-false}
  IGNORE_DISK_SPACE=${IGNORE_DISK_SPACE:-false}

  if [ ! -d "$OUTDIR" ]; then
    echo "--outdir $OUTDIR must exist"
    exit 1
  fi

  set +e
  checkStorage "$TMPDIR"
  if [ $? -ne 0 ]; then
    echo "Insufficient disk space for temporary files. Exiting."
    exit 1
  fi
  checkStorage "$OUTDIR"
  if [ $? -ne 0 ]; then
    echo "Insufficient disk space for output file. Exiting."
    exit 1
  fi
  set -e
  getDiagInfo
  compressBundle
  cleanup
}

main "$@"
