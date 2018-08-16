#! /bin/bash
# set -x

###########################################################
# @author: ziggzagg
# This is a tool composed of:
# 1. fio
# 2. iostat
# 3. gnuplot
# Use this tool to stress your storage devices
# and get plotted graphs as analysis support.
#
# Special Notice:
# We try not to use '_', but '-', to concatenate file names,
# because the former sign will distort gnuplot titles.
###########################################################



###########################################################
# TODO:
# 1. extract iostat results and plot
# 2. integrate blktrace
###########################################################



###########################################################
usage()
{
  cat << EOF >&2
  Usage: ${0##*/}
    -s scenario [iops/bandwidth/latency/fix-iops/fix-bw/fix-lat]
    -t target   [single/multiple] decives
    -m mode     [read/write/randread/randwrite/randrw]
    -h help: Show this help info.
EOF
}

if [ $# -eq 0 ]; then
    usage && exit 0
fi

fio --version > /dev/null 2>&1 || { echo "Error! Install fio first." && exit 1; }
gnuplot --version > /dev/null 2>&1 || { echo "Error! Install gnuplot first." && exit 1; }


###########################################################



###########################################################
# constants definitions:
SCENARIO_IOPS="iops"
SCENARIO_BANDWIDTH="bandwidth"
SCENARIO_LATENCY="latency"
SCENARIO_FIX_IOPS="fix-iops"
SCENARIO_FIX_BW="fix-bw"
SCENARIO_FIX_LATENCY="fix-lat"
TARGET_SINGLE="single"
TARGET_MULTIPLE="multiple"
MODE_READ="read"
MODE_WRITE="write"
MODE_RANDREAD="randread"
MODE_RANDWRITE="randwrite"
MODE_RANDRW="randrw"

DEV_LIST_FILE_NAME="device.list"
GNUPLOT_FILE_FORMAT=png


FIO_RUN_DURATION=600 #seconds
IOSTAT_RUN_INTERVAL=1 #seconds
# start behind and stop ahead:
IOSTAT_RUN_COUNT=580

# fix mode configs
IN_FIX_SCENARIO=0


# Using `io_submit_mode=offload`, iops cut half.
# ALI-SSD:208k
# AWS-SSD:387k
FIX_IOPS_READ_ARRAY=(50000 80000 100000)

# ALI-SSD:176k
# AWS-SSD:180k
FIX_IOPS_WRITE_ARRAY=(50000 80000 100000)

# ALI-SSD:202k
# AWS-SSD:370k
FIX_IOPS_RANDREAD_ARRAY=(50000 80000 100000)

# ALI-SSD:183k
# AWS-SSD:180k
FIX_IOPS_RANDWRITE_ARRAY=(50000 80000 100000)

# ALI-SSD:2097m
# AWS-SSD:2001m
FIX_BW_READ_ARRAY=(1000m 1500m 2000m)

# ALI-SSD:1258m
# AWS-SSD:801m
FIX_BW_WRITE_ARRAY=(300m 500m 800m)

# ALI-SSD:2097m
# AWS-SSD:2000m
FIX_BW_RANDREAD_ARRAY=(1000m 1500m 2000m)

# ALI-SSD:1258m
# AWS-SSD:800m
FIX_BW_RANDWRITE_ARRAY=(300m 500m 800m)

# ALI-SSD:17.46 nsec
# AWS-SSD:38.58 nsec
FIX_LATENCY_READ_ARRAY=(50)

# ALI-SSD:18.35 nsec
# AWS-SSD:39.33 nsec
FIX_LATENCY_WRITE_ARRAY=()

# ALI-SSD:61.35 nsec
# AWS-SSD:76.70 nsec
FIX_LATENCY_RANDREAD_ARRAY=()

# ALI-SSD:18.41 nsec
# AWS-SSD:39.54 nsec
FIX_LATENCY_RANDWRITE_ARRAY=()


# default variables definitions:
# be careful when re-assgining array to other variable
FIX_IOPS_ARRAY=( ${FIX_IOPS_READ_ARRAY[@]} )
FIX_BW_ARRAY=( ${FIX_BW_READ_ARRAY[@]} )
FIX_LATENCY_ARRAY=( ${FIX_LATENCY_READ_ARRAY[@]} )

# scenario should be one of "iops/bandwidth/latency"
scenario="bandwidth"
# target should be one of "single/multiple"
target="multiple"
# mode should be one of "randread/randwrite/randrw/read/write/"
mode="read"
###########################################################



###########################################################
# variables parsing:
# Do not put this into a function body.
while getopts "s:t:m:" arg; do
  case ${arg} in
    h)
      usage
      exit 0
      ;;
    s)
      scenario=${OPTARG}
      ;;
    t)
      target=${OPTARG}
      ;;
    m)
      mode=${OPTARG}
      ;;
    ?)
      echo "Error! Invalid argument: ${OPTARG}"
      exit 1
  esac
done

# Use '-eq' for numeric comparison while '==' for string
if [ ${scenario} == ${SCENARIO_FIX_IOPS} \
  -o ${scenario} == ${SCENARIO_FIX_BW}   \
  -o ${scenario} == ${SCENARIO_FIX_LATENCY} ]; then
  IN_FIX_SCENARIO=1
fi
###########################################################



###########################################################
JOB_NAME_PREFIX=${scenario}-${target}-${mode}
INI_FILE_NAME=${JOB_NAME_PREFIX}.ini
FIO_FILE_NAME=${JOB_NAME_PREFIX}.fio
IOSTAT_FILE_NAME=${JOB_NAME_PREFIX}.iostat

EXTRACTED_FIO_IOPS_FILE_NAME=${JOB_NAME_PREFIX}.fio.iops
EXTRACTED_FIO_BW_FILE_NAME=${JOB_NAME_PREFIX}.fio.bw
EXTRACTED_FIO_LAT_FILE_NAME=${JOB_NAME_PREFIX}.fio.lat

EXTRACTED_IOSTAT_IOPS_FILE_NAME=${JOB_NAME_PREFIX}.iostat.iops
EXTRACTED_IOSTAT_BW_FILE_NAME=${JOB_NAME_PREFIX}.iostat.bw
EXTRACTED_IOSTAT_LAT_FILE_NAME=${JOB_NAME_PREFIX}.iostat.lat

GNUPLOT_CONF_FILE_NAME=${JOB_NAME_PREFIX}.gnuplot

IOPS_CONFIG="
[global]
name=${JOB_NAME_PREFIX}
direct=1
sync=0
randrepeat=0
invalidate=1
time_based
norandommap
ioengine=libaio
runtime=${FIO_RUN_DURATION}
rw=${mode}
iodepth=128
blocksize=4k
write_iops_log=${mode}
log_avg_msec=1000
per_job_logs=1

"

BANDWIDTH_CONFIG="
[global]
name=${JOB_NAME_PREFIX}
direct=1
sync=0
randrepeat=0
invalidate=1
time_based
norandommap
ioengine=libaio
runtime=${FIO_RUN_DURATION}
rw=${mode}
iodepth=32
blocksize=128k
write_bw_log=${mode}
log_avg_msec=1000
per_job_logs=1

"

LATENCY_CONFIG="
[global]
name=${JOB_NAME_PREFIX}
direct=1
sync=0
randrepeat=0
invalidate=1
refill_buffers
time_based
norandommap
ioengine=libaio
runtime=${FIO_RUN_DURATION}
rw=${mode}
iodepth=1
blocksize=4k
write_lat_log=${mode}
log_avg_msec=1000
per_job_logs=1

"

FIX_IOPS_CONFIG="
[global]
name=${JOB_NAME_PREFIX}
direct=1
sync=0
randrepeat=0
invalidate=1
time_based
norandommap
ioengine=libaio
runtime=${FIO_RUN_DURATION}
rw=${mode}
iodepth=128
blocksize=4k
write_lat_log=${mode}
log_avg_msec=1000
per_job_logs=1
io_submit_mode=offload

"

FIX_BW_CONFIG="
[global]
name=${JOB_NAME_PREFIX}
direct=1
sync=0
randrepeat=0
invalidate=1
time_based
norandommap
ioengine=libaio
runtime=${FIO_RUN_DURATION}
rw=${mode}
iodepth=32
blocksize=128k
write_lat_log=${mode}
log_avg_msec=1000
per_job_logs=1
io_submit_mode=offload

"

FIX_LATENCY_CONFIG="
[global]
name=${JOB_NAME_PREFIX}
direct=1
sync=0
randrepeat=0
invalidate=1
time_based
norandommap
ioengine=libaio
runtime=${FIO_RUN_DURATION}
rw=${mode}
iodepth=1
blocksize=4k
write_lat_log=${mode}
log_avg_msec=1000
per_job_logs=1
io_submit_mode=offload

"



###########################################################



###########################################################
gen_fio_jobs()
{
  # get divice list
  local devices=""
  case ${target} in
    ${TARGET_SINGLE} )
      devices=$(cat ${DEV_LIST_FILE_NAME} | head -n 1)
      ;;
    ${TARGET_MULTIPLE} )
      devices=$(cat ${DEV_LIST_FILE_NAME})
      ;;
    * )
      echo "Error! Invalid target: ${target}"
      exit 1
      ;;
  esac

  if [[ -n ${devices} ]]; then
    local index=0
    for device in ${devices}; do
      ((index++))
      echo "[job${index}]" >> ${INI_FILE_NAME}
      echo "filename=${device}" >> ${INI_FILE_NAME}
    done
  else
    echo "Error! No available devices!"
    exit 1
  fi
}

gen_fix_fio_jobs()
{
  # get divice list
  local device=$(cat ${DEV_LIST_FILE_NAME} | tail -n 1)

  if [[ -n ${device} ]]; then
    local index=0
    case ${scenario} in
      ${SCENARIO_FIX_IOPS} )
        for fix_iops in "${FIX_IOPS_ARRAY[@]}"; do
          ((index++))
          echo "[job${index}]" >> ${INI_FILE_NAME}
          echo "stonewall" >> ${INI_FILE_NAME}
          echo "filename=${device}" >> ${INI_FILE_NAME}
          echo "rate_iops=${fix_iops}" >> ${INI_FILE_NAME}
        done
        ;;
      ${SCENARIO_FIX_BW} )
        for fix_bw in "${FIX_BW_ARRAY[@]}"; do
          ((index++))
          echo "[job${index}]" >> ${INI_FILE_NAME}
          echo "stonewall" >> ${INI_FILE_NAME}
          echo "filename=${device}" >> ${INI_FILE_NAME}
          echo "rate=${fix_bw}" >> ${INI_FILE_NAME}
        done
        ;;
      ${SCENARIO_FIX_LATENCY} )
        for fix_lat in "${FIX_LATENCY_ARRAY[@]}"; do
          ((index++))
          echo "[job${index}]" >> ${INI_FILE_NAME}
          echo "stonewall" >> ${INI_FILE_NAME}
          echo "filename=${device}" >> ${INI_FILE_NAME}
          echo "latency_target=${fix_iops}" >> ${INI_FILE_NAME}
        done
        ;;
    esac
  else
    echo "Error! No available devices!"
    exit 1
  fi
}

gen_iops_ini_file()
{
cat << EOF > ${INI_FILE_NAME}
${IOPS_CONFIG}
EOF

gen_fio_jobs
}

gen_bandwidth_ini_file()
{
cat << EOF > ${INI_FILE_NAME}
${BANDWIDTH_CONFIG}
EOF

gen_fio_jobs
}

gen_latency_ini_file()
{
cat << EOF > ${INI_FILE_NAME}
${LATENCY_CONFIG}
EOF

gen_fio_jobs
}

gen_fix_iops_ini_file()
{
cat << EOF > ${INI_FILE_NAME}
${FIX_IOPS_CONFIG}
EOF

gen_fix_fio_jobs
}

gen_fix_bw_ini_file()
{
cat << EOF > ${INI_FILE_NAME}
${FIX_BW_CONFIG}
EOF

gen_fix_fio_jobs
}

gen_fix_lat_ini_file()
{
cat << EOF > ${INI_FILE_NAME}
${FIX_LAT_CONFIG}
EOF

gen_fix_fio_jobs
}

gen_scenario_ini_file()
{
  case ${scenario} in
    ${SCENARIO_IOPS})
      gen_iops_ini_file
      ;;
    ${SCENARIO_BANDWIDTH})
      gen_bandwidth_ini_file
      ;;
    ${SCENARIO_LATENCY})
      gen_latency_ini_file
      ;;
    ${SCENARIO_FIX_IOPS})
      gen_fix_iops_ini_file
      ;;
    ${SCENARIO_FIX_BW})
      gen_fix_bw_ini_file
      ;;
    ${SCENARIO_FIX_LATENCY})
      gen_fix_lat_ini_file
      ;;
    *)
      echo "Error! Invalid scenario: ${scenario}"
      exit 1
      ;;
  esac
}
###########################################################



###########################################################

# @param $1: output graph file name (default in png format)
# @param $2: output graph title
gen_gnuplot_conf_file()
{
  local output_graph_name="${JOB_NAME_PREFIX}.${GNUPLOT_FILE_FORMAT}"
  local graph_title="${JOB_NAME_PREFIX}"
  local x_label="Time Passed / second"
  local y_label=""
  local label_info=""
  local quote='"'
  case ${scenario} in
    ${SCENARIO_IOPS} | ${SCENARIO_FIX_LATENCY})
      y_label="IOPS"
      label_info=$(cat ${EXTRACTED_FIO_IOPS_FILE_NAME} | sed -E ':a;N;$!ba;s/\r{0,1}\n/\\n/g')
      ;;
    ${SCENARIO_BANDWIDTH})
      y_label="Bandwidth KiB/s"
      label_info=$(cat ${EXTRACTED_FIO_BW_FILE_NAME} | sed -E ':a;N;$!ba;s/\r{0,1}\n/\\n/g')
      ;;
    ${SCENARIO_LATENCY} | ${SCENARIO_FIX_IOPS} | ${SCENARIO_FIX_BW})
      y_label="Latency nsec"
      label_info=$(cat ${EXTRACTED_FIO_LAT_FILE_NAME} | sed -E ':a;N;$!ba;s/\r{0,1}\n/\\n/g')
      ;;
  esac

cat << EOF > ${GNUPLOT_CONF_FILE_NAME}
set terminal ${GNUPLOT_FILE_FORMAT}  transparent enhanced font "arial,10" fontscale 1.0 size 800, 600
set output '${output_graph_name}'
set yrange [0:*]
set style data lines
set title '${graph_title}'
set xlabel '${x_label}'
set ylabel '${y_label}'
set label 1 ${quote}${label_info}${quote} at graph 0.9, graph 0.2 right textcolor rgb "#000000"
DEBUG_TERM_HTIC = 119
DEBUG_TERM_VTIC = 119

EOF
}


gen_fio_csv_file_and_graph()
{
  local plotting_command="plot"
  for log_file in $@; do # use '$@' instead of '$1'
    local index=$(grep '[0-9]\+' -o <<< ${log_file})
    local csv_file=${log_file/log/csv}
    # 1. ',' seperated
    # 2. +11 to handle 999/1000=0 case
    # 3. put a space after each ',' to make gnuplot happy
    awk -F, 'FNR>10 {printf("%d, %d\n", ($1+11)/1000, $2)}' ${log_file} > ${csv_file}
    local title=""

    if [ ${IN_FIX_SCENARIO} -eq 1 ]; then
      local p=$((index-1))
      case ${scenario} in
        ${SCENARIO_FIX_IOPS} )
          title="IOPS=${FIX_IOPS_ARRAY[${p}]}"
          ;;
        ${SCENARIO_FIX_BW} )
          title="BW=${FIX_BW_ARRAY[${p}]}"
          ;;
        ${SCENARIO_FIX_LATENCY} )
          title="LAT=${FIX_LATENCY_ARRAY[${p}]}"
          ;;
      esac
    else
      title=$(cat ${DEV_LIST_FILE_NAME} | sed "${index}q;d")
    fi

    plotting_command="${plotting_command} '${csv_file}' using 1:2 title '${title}', "
  done

  plotting_command=${plotting_command::-2}
  gen_gnuplot_conf_file

  # draw multiple flows into one graph file
  echo ${plotting_command} >> ${GNUPLOT_CONF_FILE_NAME}
  gnuplot ${GNUPLOT_CONF_FILE_NAME}
}

handle_iops_results()
{
  # extract iops from fio results
  grep "IOPS=[ 0-9.]\+k*" ${FIO_FILE_NAME} -o > ${EXTRACTED_FIO_IOPS_FILE_NAME}
  gen_fio_csv_file_and_graph $(find ${mode}_iops.*.log)
}

handle_bw_results()
{
  grep "BW=[ 0-9.]\+[KMG]iB/s ([0-9.]\+[kMG]B/s)" ${FIO_FILE_NAME} -o > ${EXTRACTED_FIO_BW_FILE_NAME}
  gen_fio_csv_file_and_graph $(find ${mode}_bw.*.log)
}

handle_latency_results()
{
  grep " lat ([num]sec): min=[ 0-9.]\+k*, max=[ 0-9.]\+k*, avg=[ 0-9.]\+k*, stdev=[ 0-9.]\+k*" ${FIO_FILE_NAME} -o > ${EXTRACTED_FIO_LAT_FILE_NAME}
  gen_fio_csv_file_and_graph $(find ${mode}_lat.*.log)
}

handle_results()
{
  case ${scenario} in
    ${SCENARIO_IOPS})
      handle_iops_results
      ;;
    ${SCENARIO_BANDWIDTH})
      handle_bw_results
      ;;
    ${SCENARIO_LATENCY})
      handle_latency_results
      ;;
    ${SCENARIO_FIX_IOPS})
      handle_latency_results
      ;;
    ${SCENARIO_FIX_BW})
      handle_latency_results
      ;;
    ${SCENARIO_FIX_LATENCY})
      handle_iops_results
      ;;
    *)
      echo "Error! Invalid scenario: ${scenario}"
      exit 1
      ;;
  esac
}
###########################################################



###########################################################
# Use this script to run multiple scenarios:
#
run()
{
  #!/bin/bash

  s=( iops bandwidth latency fix-iops fix-bw fix-lat)
  t=( single multiple )
  m=( read write randread randwrite )

  for s1 in "${s[@]}"; do
    for t1 in "${t[@]}"; do
      for m1 in "${m[@]}"; do
        ./fio.sh -s $s1 -t $t1 -m $m1
      done
    done
  done
}
###########################################################



###########################################################
main()
{
  # begin main:

  # make working directory
  current_time=$(date +"%Y-%m-%d")
  working_dir=${JOB_NAME_PREFIX}-${current_time}
  mkdir ${working_dir} && cd ${working_dir} || exit 1

  # list devices
  $(lsblk -pdr | grep -vE ":0\s|NAME" | awk '{print $1}' > ${DEV_LIST_FILE_NAME})
  # $(lsblk -pdr | grep -vE "vda|NAME" | awk '{print $1}' > ${DEV_LIST_FILE_NAME})
  if [[ ! -s ${DEV_LIST_FILE_NAME} ]]; then
    echo "Error! No available devices!"
    exit 1
  fi

  case ${mode} in
    ${MODE_READ} )
      FIX_IOPS_ARRAY=( ${FIX_IOPS_READ_ARRAY[@]} )
      FIX_BW_ARRAY=( ${FIX_BW_READ_ARRAY[@]} )
      FIX_LATENCY_ARRAY=( ${FIX_LATENCY_READ_ARRAY[@]} )
      ;;
    ${MODE_WRITE} )
      FIX_IOPS_ARRAY=( ${FIX_IOPS_WRITE_ARRAY[@]} )
      FIX_BW_ARRAY=( ${FIX_BW_WRITE_ARRAY[@]} )
      FIX_LATENCY_ARRAY=( ${FIX_LATENCY_READ_ARRAY[@]} )
      ;;
    ${MODE_RANDREAD} )
      FIX_IOPS_ARRAY=( ${FIX_IOPS_RANDREAD_ARRAY[@]} )
      FIX_BW_ARRAY=( ${FIX_BW_RANDREAD_ARRAY[@]} )
      FIX_LATENCY_ARRAY=( ${FIX_LATENCY_RANDREAD_ARRAY[@]} )
      ;;
    ${MODE_RANDWRITE} )
      FIX_IOPS_ARRAY=( ${FIX_IOPS_RANDWRITE_ARRAY[@]} )
      FIX_BW_ARRAY=( ${FIX_BW_RANDWRITE_ARRAY[@]} )
      FIX_LATENCY_ARRAY=( ${FIX_LATENCY_RANDWRITE_ARRAY[@]} )
      ;;
    ${MODE_RANDRW} )
      # TODO: Implement this.
      ;;
  esac

  echo "Generating fio config file ..."
  gen_scenario_ini_file

  if [ ${IN_FIX_SCENARIO} -eq 0 ]; then
    # start fio testing, as background task:
    echo "Starting ${JOB_NAME_PREFIX} fio ..."
    sudo fio ${INI_FILE_NAME} > ${FIO_FILE_NAME} 2>&1 &

    sleep 10

    # start iostat collection, as background task:
    echo "Starting ${JOB_NAME_PREFIX} iostat ..."
    iostat -dkx ${IOSTAT_RUN_INTERVAL} ${IOSTAT_RUN_COUNT} > ${IOSTAT_FILE_NAME} 2>&1 &

    echo "OK! Wait ${FIO_RUN_DURATION} seconds."

    sleep ${FIO_RUN_DURATION}
  else
    # start iostat collection, as background task:
    echo "Starting ${JOB_NAME_PREFIX} iostat ..."
    iostat -dkx ${IOSTAT_RUN_INTERVAL} ${IOSTAT_RUN_COUNT} > ${IOSTAT_FILE_NAME} 2>&1 &

    # we do not know what time the fio process ends, so just run it in foreground
    echo "Starting ${JOB_NAME_PREFIX} fio ..."
    sudo fio ${INI_FILE_NAME} > ${FIO_FILE_NAME} 2>&1
  fi

  echo "Formatting results and plotting graphs ..."
  handle_results

  echo "All done!"
  exit 0
}

main
