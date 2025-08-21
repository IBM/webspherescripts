#!/bin/sh
# diagnostics.sh: Gather various Linux and Java diagnostics
# Copyright IBM Corporation. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# This script is provided as-is without warranty or support.

VERSION="0.20250821.2"
echo "$(basename "${0}") version ${VERSION} is provided as-is without warranty or support."

usage() {
  printf "Usage: %s -a ACTION [OPTIONAL_ARGS...]\n" "$(basename "${0}")"
  cat <<EOF
         -a ACTION
            start: Start diagnostics in background
            collect: Stop any running diagnostics, create a .tar.gz file and clean up files
            stop: Stop any running diagnostics
            status: Show which diagnostic commands are running
            singlecollection: Gather a single collection of the diagnostics
         -d DELAY: Interval in seconds between various background collections. Default: 1800 (30mins)
         -f TCPDUMP_MAX_FILESIZE: Maximum file size in MB of each tcpdump file. Default: 100
         -i TCPDUMP_INTERFACE: The network interface for tcpdump to capture. Default: any (all interfaces)
         -n TCPDUMP_MAX_FILES: Maximum number of tcpdump files. Default: 10
         -v VERBOSE: 1 to enable verbose logging and 0 to disable. Default: 0

Notes:
1. Data is collected in the current working directory.
2. For the background collection (-a start), by default, tcpdump can generate up to 1GB.

Example usage:

A) Simple, single data collection:
1. ${0} -a singlecollection

B) Proactive data collection
1. Start diagnostics: ${0} -a start
2. Reproduce the problem
3. Stop and collect diagnostics: ${0} -a collect
4. Upload the resulting diag*.tar.gz file

EOF
  exit 22
}

if [ "$(id -u)" != "0" ]; then
  echo "ERROR: This script must be run as root (for tcpdump, etc.)"
  exit 1
fi

# Defaults
ACTION=""
OUTPUTSUFFIX="$(hostname)"
WRAPPER_OUTPUTFILE="diag_output_${OUTPUTSUFFIX}.txt"
TOOL_OUTPUTFILE_PREFIX="diag_tool_output"
DELAYSECONDS="1800" # 30 mins
INTERFACE="any"
MARKER=""
VERBOSE="0"
TCPDUMP_MAXFILESIZE_MB="100"
TCPDUMP_MAXFILES="10"

# Options processing
while getopts "a:d:f:hi:m:n:o:v:" opt; do
  case "$opt" in
    a)
      ACTION="${OPTARG}"
      ;;
    d)
      DELAYSECONDS="${OPTARG}"
      ;;
    f)
      TCPDUMP_MAXFILESIZE_MB="${OPTARG}"
      ;;
    h)
      usage
      ;;
    i)
      INTERFACE="${OPTARG}"
      ;;
    m)
      MARKER="${OPTARG}"
      ;;
    n)
      TCPDUMP_MAXFILES="${OPTARG}"
      ;;
    o)
      WRAPPER_OUTPUTFILE="${OPTARG}"
      ;;
    v)
      VERBOSE="${OPTARG}"
      ;;
  esac
done

if [ "${ACTION}" = "" ]; then
  usage
fi

stopDiagnostics() {
  if [ "$(pgrep -a -f ${TOOL_OUTPUTFILE_PREFIX})" != "" ]; then
    echo "[$(date)] Stopping diagnostic processes" | tee -a "${WRAPPER_OUTPUTFILE}"
    [ "${VERBOSE}" = "1" ] && echo "[$(date)] Stopping process trees of:" | tee -a "${WRAPPER_OUTPUTFILE}"
    [ "${VERBOSE}" = "1" ] && echo "$(pgrep -a -f ${TOOL_OUTPUTFILE_PREFIX})" | tee -a "${WRAPPER_OUTPUTFILE}"

    # We need to kill the entire process tree so we use the process group
    for PID in $(pgrep -f ${TOOL_OUTPUTFILE_PREFIX}); do
      PGID="$(ps -o pgid= ${PID} | awk '{print $1}')"
      if [ "${PGID}" != "" ]; then
        [ "${VERBOSE}" = "1" ] && echo "[$(date)] Process group ID of ${PID} is ${PGID}" | tee -a "${WRAPPER_OUTPUTFILE}"
        kill -INT -${PGID}
        sleep 1
        kill -TERM -${PGID} 2>/dev/null
      fi
    done
    [ "${VERBOSE}" = "1" ] && echo "[$(date)] After clean up (expecting blank): $(pgrep -a -f ${TOOL_OUTPUTFILE_PREFIX})" | tee -a "${WRAPPER_OUTPUTFILE}"
    echo "[$(date)] Diagnostic processes stopped" | tee -a "${WRAPPER_OUTPUTFILE}"
  fi

  # Gather any one-time data
  journalctl > "${TOOL_OUTPUTFILE_PREFIX}_journal_${OUTPUTSUFFIX}.txt" 2>&1
  date >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  echo "Gathering uname -a" >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  uname -a >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  echo "Gathering uptime" >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  uptime >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  echo "Gathering meminfo" >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  cat /proc/meminfo >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  echo "Gathering cpuinfo" >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  cat /proc/cpuinfo >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  echo "Gathering netstat -antop" >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  netstat -antop >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  echo "Gathering netstat -s" >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  netstat -s >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  echo "Gathering ps" >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  ps -elfyww >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  echo "Gathering top" >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  top -b -d 2 -n 1 >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  echo "Gathering df" >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
  df -h >> ${TOOL_OUTPUTFILE_PREFIX}_basicinfo_${OUTPUTSUFFIX}.txt 2>&1
}

printProcessTree() {
  ps -elfyww | awk "\$3 == $1"
  for PID in $(ps -elfyww | awk "\$4 == $1 { print \$3; }"); do
    printProcessTree $PID
  done
}

echoEntry() {
  echo "[$(date)] Running $(basename "${0}") version ${VERSION} with action ${ACTION}" | tee -a "${WRAPPER_OUTPUTFILE}"
  echo "[$(date)] Started with options: ${@}" >> "${WRAPPER_OUTPUTFILE}" 2>&1
}

echoExit() {
  echo "[$(date)] Action ${ACTION} successfully completed" | tee -a "${WRAPPER_OUTPUTFILE}"
}

collectMainData() {
  echo "[$(date)] Executing iteration" >> "${WRAPPER_OUTPUTFILE}" 2>&1

  echo "[$(date)] Executing top" >> "${TOOL_OUTPUTFILE_PREFIX}_top_${OUTPUTSUFFIX}.txt" 2>&1
  top -b -d 2 -n 1 -o %MEM >> "${TOOL_OUTPUTFILE_PREFIX}_top_${OUTPUTSUFFIX}.txt" 2>&1

  echo "[$(date)] Executing top -H" >> "${TOOL_OUTPUTFILE_PREFIX}_topH_${OUTPUTSUFFIX}.txt" 2>&1
  top -b -H -d 2 -n 1 >> "${TOOL_OUTPUTFILE_PREFIX}_topH_${OUTPUTSUFFIX}.txt" 2>&1

  echo "[$(date)] Executing netstat -antop" >> "${TOOL_OUTPUTFILE_PREFIX}_netstat_${OUTPUTSUFFIX}.txt" 2>&1
  netstat -antop >> "${TOOL_OUTPUTFILE_PREFIX}_netstat_${OUTPUTSUFFIX}.txt" 2>&1

  echo "[$(date)] Executing netstat -s" >> "${TOOL_OUTPUTFILE_PREFIX}_statistics_netstat_${OUTPUTSUFFIX}.txt" 2>&1
  netstat -s >> "${TOOL_OUTPUTFILE_PREFIX}_statistics_netstat_${OUTPUTSUFFIX}.txt" 2>&1

  echo "[$(date)] Executing ps -elfyww" >> "${TOOL_OUTPUTFILE_PREFIX}_ps_${OUTPUTSUFFIX}.txt" 2>&1
  ps -elfyww >> "${TOOL_OUTPUTFILE_PREFIX}_ps_${OUTPUTSUFFIX}.txt" 2>&1

  echo "[$(date)] Executing df" >> "${TOOL_OUTPUTFILE_PREFIX}_df_${OUTPUTSUFFIX}.txt" 2>&1
  df -h >> "${TOOL_OUTPUTFILE_PREFIX}_df_${OUTPUTSUFFIX}.txt" 2>&1

  echo "[$(date)] Getting meminfo" >> "${TOOL_OUTPUTFILE_PREFIX}_meminfo_${OUTPUTSUFFIX}.txt" 2>&1
  cat /proc/meminfo >> "${TOOL_OUTPUTFILE_PREFIX}_meminfo_${OUTPUTSUFFIX}.txt" 2>&1

  # We don't take javacores of NoAppServer and QueueController because they're configured to create PHDs on kill -3 which are impactful and consume a lot of disk
  for PID in $(ps -elfyww | awk '/java / && !/java_wrapper/ && !/NoAppServer/ && !/QueueController/ { print $3; }'); do
    echo "[$(date)] Gathering data on Java PID ${PID} ; threads = $(ps -L -p ${PID} | wc -l); javacore directory likely = $(ls -l /proc/$PID/cwd | sed 's/.*-> //g')" >> "${WRAPPER_OUTPUTFILE}" 2>&1
    echo "$(ls -l /proc/$PID/cwd | sed 's/.*-> //g')" >> "${TOOL_OUTPUTFILE_PREFIX}_java_cwds_${OUTPUTSUFFIX}.txt" 2>&1
    echo "[$(date)] Getting smaps for ${PID}" >> "${TOOL_OUTPUTFILE_PREFIX}_smaps_${OUTPUTSUFFIX}.txt" 2>&1
    cat /proc/${PID}/smaps >> "${TOOL_OUTPUTFILE_PREFIX}_smaps_${OUTPUTSUFFIX}.txt" 2>&1
    kill -3 ${PID}
  done
  echo "[$(date)] Sleeping for ${DELAYSECONDS} seconds..." >> "${WRAPPER_OUTPUTFILE}" 2>&1
}

performCollect() {
  stopDiagnostics
  TARFILE="diag_$(hostname)_$(date +%Y%m%d_%H%M%S).tar.gz"
  echo "[$(date)] Creating tar file ${TARFILE}..."
  JAVACORES="$(cat ${TOOL_OUTPUTFILE_PREFIX}_java_cwds_${OUTPUTSUFFIX}.txt 2>/dev/null | sort | uniq | while read line; do ls "${line}/javacore"*; done | xargs)"
  tar --ignore-failed-read -czf ${TARFILE} diag_output* diag_tool_output* ${JAVACORES} 2>&1 | grep -v -e "Removing leading" -e "diag_.* Warning: Cannot stat: No such file or directory"
  if [ -f "${TARFILE}" ]; then
    rm -f diag_output*
    rm -f diag_tool_output*
    rm -f ${JAVACORES}
  fi
  echo "[$(date)] Finished creating tar file: ${TARFILE}"
  if command -v readlink >/dev/null 2>&1; then
    readlink -f ${TARFILE}
  fi
}

case "${ACTION}" in
  start)
    echoEntry

    # First we stop any pre-existing diagnostics in case the user forgot to clean
    # up the last run of this script.
    stopDiagnostics

    # Start tcpdump
    echo "[$(date)] Starting tcpdump with up to ${TCPDUMP_MAXFILES} files of ${TCPDUMP_MAXFILESIZE_MB}MB each. Free space in this directory:" | tee -a "${WRAPPER_OUTPUTFILE}"
    df -h . | tee -a "${WRAPPER_OUTPUTFILE}"
    nohup tcpdump -nn -v -i $INTERFACE -B 4096 -s 80 -C "${TCPDUMP_MAXFILESIZE_MB}" -W "${TCPDUMP_MAXFILES}" -Z root -w ${TOOL_OUTPUTFILE_PREFIX}_tcpdump_${OUTPUTSUFFIX}.pcap >> "${TOOL_OUTPUTFILE_PREFIX}_tcpdump_${OUTPUTSUFFIX}.txt" 2>&1 &

    # Start ourselves with the background action with nohup.
    # The -m marker option is just so that we can find what we started with pgrep during the stop operation
    echo "[$(date)] Starting background child tasks. Please wait..." | tee -a "${WRAPPER_OUTPUTFILE}"
    nohup sh ${0} -a background -m "${TOOL_OUTPUTFILE_PREFIX}" -o "${WRAPPER_OUTPUTFILE}" -v "${VERBOSE}" -d "${DELAYSECONDS}" >> "${WRAPPER_OUTPUTFILE}" 2>&1 &

    # Wait a bit of time so that in case the user starts and then quickly
    # wants to stop, then we'll hopefully have gotten the first iteration of background data
    sleep 5

    echo "[$(date)] Diagnostics successfully started in the background" | tee -a "${WRAPPER_OUTPUTFILE}"
    ;;
  stop)
    echoEntry
    stopDiagnostics
    echoExit
    ;;
  status)
    PIDS="$(pgrep -f ${TOOL_OUTPUTFILE_PREFIX})"
    if [ "${PIDS}" != "" ]; then
      ps -elfyww | head -1
      for PID in ${PIDS}; do
        printProcessTree $PID
      done
    else
      echo "No diagnostics running"
    fi
    ;;
  collect)
    performCollect
    ;;
  clean)
    stopDiagnostics
    if [ -f "${TOOL_OUTPUTFILE_PREFIX}_java_cwds_${OUTPUTSUFFIX}.txt" ]; then
      JAVACORES="$(cat ${TOOL_OUTPUTFILE_PREFIX}_java_cwds_${OUTPUTSUFFIX}.txt | sort | uniq | while read line; do ls "${line}/javacore"*; done | xargs)"
      if [ "${JAVACORES}" != "" ]; then
        rm -vf ${JAVACORES}
      fi
    fi
    rm -vf diag_output*
    rm -vf diag_tool_output*
    ;;
  background)
    echo "[$(date)] Running $(basename "${0}") with action ${ACTION}" >> "${WRAPPER_OUTPUTFILE}" 2>&1
    while true; do
      collectMainData
      sleep ${DELAYSECONDS}
    done
    echo "[$(date)] Action ${ACTION} successfully completed" >> "${WRAPPER_OUTPUTFILE}" 2>&1
    ;;
  singlecollection)
    echoEntry

    # First we stop any pre-existing diagnostics in case the user forgot to clean
    # up the last run of this script.
    stopDiagnostics

    echo "[$(date)] Performing single collection" | tee -a "${WRAPPER_OUTPUTFILE}"

    collectMainData

    echo "[$(date)] Gathering and packaging files" | tee -a "${WRAPPER_OUTPUTFILE}"

    performCollect
    ;;
  *)
    echo "ERROR: Unknown action ${ACTION}"
    exit 1
    ;;
esac
