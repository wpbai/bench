#!/usr/bin/env bash
#
# Description: A Bench Script by Teddysun
#
# Copyright (C) 2015 - 2023 Teddysun <i@teddysun.com>
# Thanks: LookBack <admin@dwhd.org>
# URL: https://teddysun.com/444.html
# https://github.com/teddysun/across/blob/master/bench.sh
#
trap _exit INT QUIT TERM

_red() {
    printf '\033[0;31;31m%b\033[0m' "$1"
}

_green() {
    printf '\033[0;31;32m%b\033[0m' "$1"
}

_yellow() {
    printf '\033[0;31;33m%b\033[0m' "$1"
}

_blue() {
    printf '\033[0;31;36m%b\033[0m' "$1"
}

_exists() {
    local cmd="$1"
    if eval type type > /dev/null 2>&1; then
        eval type "$cmd" > /dev/null 2>&1
    elif command > /dev/null 2>&1; then
        command -v "$cmd" > /dev/null 2>&1
    else
        which "$cmd" > /dev/null 2>&1
    fi
    local rt=$?
    return ${rt}
}

_exit() {
    _red "\nThe script has been terminated. Cleaning up files...\n"
    # clean up
    rm -fr speedtest.tgz speedtest-cli benchtest_*
    exit 1
}

get_opsy() {
    [ -f /etc/redhat-release ] && awk '{print $0}' /etc/redhat-release && return
    [ -f /etc/os-release ] && awk -F'[= "]' '/PRETTY_NAME/{print $3,$4,$5}' /etc/os-release && return
    [ -f /etc/lsb-release ] && awk -F'[="]+' '/DESCRIPTION/{print $2}' /etc/lsb-release && return
}

next() {
    printf "%-70s\n" "-" | sed 's/\s/-/g'
}
# disk_test
# Purpose: This method is designed to test the disk performance of the host using the partition that the
#          script is being run from using fio random read/write speed tests.
# Parameters:
#          - (none)
function disk_test {
	if [[ "$ARCH" = "aarch64" || "$ARCH" = "arm" ]]; then
		FIO_SIZE=512M
	else
		FIO_SIZE=2G
	fi

	# run a quick test to generate the fio test file to be used by the actual tests
	echo -en "Generating fio test file..."
	$FIO_CMD --name=setup --ioengine=libaio --rw=read --bs=64k --iodepth=64 --numjobs=2 --size=$FIO_SIZE --runtime=1 --gtod_reduce=1 --filename=$DISK_PATH/test.fio --direct=1 --minimal &> /dev/null
	echo -en "\r\033[0K"

	# get array of block sizes to evaluate
	BLOCK_SIZES=("$@")

	for BS in "${BLOCK_SIZES[@]}"; do
		# run rand read/write mixed fio test with block size = $BS
		echo -en "Running fio random mixed R+W disk test with $BS block size..."
		DISK_TEST=$(timeout 35 $FIO_CMD --name=rand_rw_$BS --ioengine=libaio --rw=randrw --rwmixread=50 --bs=$BS --iodepth=64 --numjobs=2 --size=$FIO_SIZE --runtime=30 --gtod_reduce=1 --direct=1 --filename=$DISK_PATH/test.fio --group_reporting --minimal 2> /dev/null | grep rand_rw_$BS)
		DISK_IOPS_R=$(echo $DISK_TEST | awk -F';' '{print $8}')
		DISK_IOPS_W=$(echo $DISK_TEST | awk -F';' '{print $49}')
		DISK_IOPS=$(awk -v a="$DISK_IOPS_R" -v b="$DISK_IOPS_W" 'BEGIN { print a + b }')
		DISK_TEST_R=$(echo $DISK_TEST | awk -F';' '{print $7}')
		DISK_TEST_W=$(echo $DISK_TEST | awk -F';' '{print $48}')
		DISK_TEST=$(awk -v a="$DISK_TEST_R" -v b="$DISK_TEST_W" 'BEGIN { print a + b }')
		DISK_RESULTS_RAW+=( "$DISK_TEST" "$DISK_TEST_R" "$DISK_TEST_W" "$DISK_IOPS" "$DISK_IOPS_R" "$DISK_IOPS_W" )

		DISK_IOPS=$(format_iops $DISK_IOPS)
		DISK_IOPS_R=$(format_iops $DISK_IOPS_R)
		DISK_IOPS_W=$(format_iops $DISK_IOPS_W)
		DISK_TEST=$(format_speed $DISK_TEST)
		DISK_TEST_R=$(format_speed $DISK_TEST_R)
		DISK_TEST_W=$(format_speed $DISK_TEST_W)

		DISK_RESULTS+=( "$DISK_TEST" "$DISK_TEST_R" "$DISK_TEST_W" "$DISK_IOPS" "$DISK_IOPS_R" "$DISK_IOPS_W" )
		echo -en "\r\033[0K"
	done
}

# dd_test
# Purpose: This method is invoked if the fio disk test failed. dd sequential speed tests are
#          not indiciative or real-world results, however, some form of disk speed measure 
#          is better than nothing.
# Parameters:
#          - (none)
function dd_test {
	I=0
	DISK_WRITE_TEST_RES=()
	DISK_READ_TEST_RES=()
	DISK_WRITE_TEST_AVG=0
	DISK_READ_TEST_AVG=0

	# run the disk speed tests (write and read) thrice over
	while [ $I -lt 3 ]
	do
		# write test using dd, "direct" flag is used to test direct I/O for data being stored to disk
		DISK_WRITE_TEST=$(dd if=/dev/zero of=$DISK_PATH/$DATE.test bs=64k count=16k oflag=direct |& grep copied | awk '{ print $(NF-1) " " $(NF)}')
		VAL=$(echo $DISK_WRITE_TEST | cut -d " " -f 1)
		[[ "$DISK_WRITE_TEST" == *"GB"* ]] && VAL=$(awk -v a="$VAL" 'BEGIN { print a * 1000 }')
		DISK_WRITE_TEST_RES+=( "$DISK_WRITE_TEST" )
		DISK_WRITE_TEST_AVG=$(awk -v a="$DISK_WRITE_TEST_AVG" -v b="$VAL" 'BEGIN { print a + b }')

		# read test using dd using the 1G file written during the write test
		DISK_READ_TEST=$(dd if=$DISK_PATH/$DATE.test of=/dev/null bs=8k |& grep copied | awk '{ print $(NF-1) " " $(NF)}')
		VAL=$(echo $DISK_READ_TEST | cut -d " " -f 1)
		[[ "$DISK_READ_TEST" == *"GB"* ]] && VAL=$(awk -v a="$VAL" 'BEGIN { print a * 1000 }')
		DISK_READ_TEST_RES+=( "$DISK_READ_TEST" )
		DISK_READ_TEST_AVG=$(awk -v a="$DISK_READ_TEST_AVG" -v b="$VAL" 'BEGIN { print a + b }')

		I=$(( $I + 1 ))
	done
	# calculate the write and read speed averages using the results from the three runs
	DISK_WRITE_TEST_AVG=$(awk -v a="$DISK_WRITE_TEST_AVG" 'BEGIN { print a / 3 }')
	DISK_READ_TEST_AVG=$(awk -v a="$DISK_READ_TEST_AVG" 'BEGIN { print a / 3 }')
}

# check if disk performance is being tested and the host has required space (2G)
AVAIL_SPACE=$(df -k . | awk 'NR==2{print $4}')
if [[ -z "$SKIP_FIO" && "$AVAIL_SPACE" -lt 2097152 && "$ARCH" != "aarch64" && "$ARCH" != "arm" ]]; then # 2GB = 2097152KB
	echo -e "\nLess than 2GB of space available. Skipping disk test..."
elif [[ -z "$SKIP_FIO" && "$AVAIL_SPACE" -lt 524288 && ("$ARCH" = "aarch64" || "$ARCH" = "arm") ]]; then # 512MB = 524288KB
	echo -e "\nLess than 512MB of space available. Skipping disk test..."
# if the skip disk flag was set, skip the disk performance test, otherwise test disk performance
elif [ -z "$SKIP_FIO" ]; then
	# Perform ZFS filesystem detection and determine if we have enough free space according to spa_asize_inflation
	ZFSCHECK="/sys/module/zfs/parameters/spa_asize_inflation"
	if [[ -f "$ZFSCHECK" ]];then
		mul_spa=$((($(cat /sys/module/zfs/parameters/spa_asize_inflation)*2)))
		warning=0
		poss=()

		for pathls in $(df -Th | awk '{print $7}' | tail -n +2)
		do
			if [[ "${PWD##$pathls}" != "${PWD}" ]]; then
				poss+=($pathls)
			fi
		done

		long=""
		m=-1
		for x in ${poss[@]}
		do
			if [ ${#x} -gt $m ];then
				m=${#x}
				long=$x
			fi
		done

		size_b=$(df -Th | grep -w $long | grep -i zfs | awk '{print $5}' | tail -c 2 | head -c 1)
		free_space=$(df -Th | grep -w $long | grep -i zfs | awk '{print $5}' | head -c -2)

		if [[ $size_b == 'T' ]]; then
			free_space=$(bc <<< "$free_space*1024")
			size_b='G'
		fi

		if [[ $(df -Th | grep -w $long) == *"zfs"* ]];then

			if [[ $size_b == 'G' ]]; then
				if [[ $(echo "$free_space < $mul_spa" | bc) -ne 0 ]];then
					warning=1
				fi
			else
				warning=1
			fi

		fi

		if [[ $warning -eq 1 ]];then
			echo -en "\nWarning! You are running YABS on a ZFS Filesystem and your disk space is too low for the fio test. Your test results will be inaccurate. You need at least $mul_spa GB free in order to complete this test accurately. For more information, please see https://github.com/masonr/yet-another-bench-script/issues/13\n"
		fi
	fi
	
	echo -en "\nPreparing system for disk tests..."

	# create temp directory to store disk write/read test files
	DISK_PATH=$YABS_PATH/disk
	mkdir -p $DISK_PATH

	if [[ -z "$PREFER_BIN" && ! -z "$LOCAL_FIO" ]]; then # local fio has been detected, use instead of pre-compiled binary
		FIO_CMD=fio
	else
		# download fio binary
		if [[ ! -z $LOCAL_CURL ]]; then
			curl -s --connect-timeout 5 --retry 5 --retry-delay 0 https://raw.githubusercontent.com/masonr/yet-another-bench-script/master/bin/fio/fio_$ARCH -o $DISK_PATH/fio
		else
			wget -q -T 5 -t 5 -w 0 https://raw.githubusercontent.com/masonr/yet-another-bench-script/master/bin/fio/fio_$ARCH -O $DISK_PATH/fio
		fi

		if [ ! -f "$DISK_PATH/fio" ]; then # ensure fio binary download successfully
			echo -en "\r\033[0K"
			echo -e "Fio binary download failed. Running dd test as fallback...."
			DD_FALLBACK=True
		else
			chmod +x $DISK_PATH/fio
			FIO_CMD=$DISK_PATH/fio
		fi
	fi

	if [ -z "$DD_FALLBACK" ]; then # if not falling back on dd tests, run fio test
		echo -en "\r\033[0K"

		# init global array to store disk performance values
		declare -a DISK_RESULTS DISK_RESULTS_RAW
		# disk block sizes to evaluate
		BLOCK_SIZES=( "4k" "64k" "512k" "1m" )

		# execute disk performance test
		disk_test "${BLOCK_SIZES[@]}"
	fi

	if [[ ! -z "$DD_FALLBACK" || ${#DISK_RESULTS[@]} -eq 0 ]]; then # fio download failed or test was killed or returned an error, run dd test instead
		if [ -z "$DD_FALLBACK" ]; then # print error notice if ended up here due to fio error
			echo -e "fio disk speed tests failed. Run manually to determine cause.\nRunning dd test as fallback..."
		fi

		dd_test

		# format the speed averages by converting to GB/s if > 1000 MB/s
		if [ $(echo $DISK_WRITE_TEST_AVG | cut -d "." -f 1) -ge 1000 ]; then
			DISK_WRITE_TEST_AVG=$(awk -v a="$DISK_WRITE_TEST_AVG" 'BEGIN { print a / 1000 }')
			DISK_WRITE_TEST_UNIT="GB/s"
		else
			DISK_WRITE_TEST_UNIT="MB/s"
		fi
		if [ $(echo $DISK_READ_TEST_AVG | cut -d "." -f 1) -ge 1000 ]; then
			DISK_READ_TEST_AVG=$(awk -v a="$DISK_READ_TEST_AVG" 'BEGIN { print a / 1000 }')
			DISK_READ_TEST_UNIT="GB/s"
		else
			DISK_READ_TEST_UNIT="MB/s"
		fi

		# print dd sequential disk speed test results
		echo -e
		echo -e "dd Sequential Disk Speed Tests:"
		echo -e "---------------------------------"
		printf "%-6s | %-6s %-4s | %-6s %-4s | %-6s %-4s | %-6s %-4s\n" "" "Test 1" "" "Test 2" ""  "Test 3" "" "Avg" ""
		printf "%-6s | %-6s %-4s | %-6s %-4s | %-6s %-4s | %-6s %-4s\n"
		printf "%-6s | %-11s | %-11s | %-11s | %-6.2f %-4s\n" "Write" "${DISK_WRITE_TEST_RES[0]}" "${DISK_WRITE_TEST_RES[1]}" "${DISK_WRITE_TEST_RES[2]}" "${DISK_WRITE_TEST_AVG}" "${DISK_WRITE_TEST_UNIT}" 
		printf "%-6s | %-11s | %-11s | %-11s | %-6.2f %-4s\n" "Read" "${DISK_READ_TEST_RES[0]}" "${DISK_READ_TEST_RES[1]}" "${DISK_READ_TEST_RES[2]}" "${DISK_READ_TEST_AVG}" "${DISK_READ_TEST_UNIT}" 
	else # fio tests completed successfully, print results
		[[ ! -z $JSON ]] && JSON_RESULT+=',"fio":['
		DISK_RESULTS_NUM=$(expr ${#DISK_RESULTS[@]} / 6)
		DISK_COUNT=0

		# print disk speed test results
		echo -e "fio Disk Speed Tests (Mixed R/W 50/50):"
		echo -e "---------------------------------"

		while [ $DISK_COUNT -lt $DISK_RESULTS_NUM ] ; do
			if [ $DISK_COUNT -gt 0 ]; then printf "%-10s | %-20s | %-20s\n"; fi
			printf "%-10s | %-11s %8s | %-11s %8s\n" "Block Size" "${BLOCK_SIZES[DISK_COUNT]}" "(IOPS)" "${BLOCK_SIZES[DISK_COUNT+1]}" "(IOPS)"
			printf "%-10s | %-11s %8s | %-11s %8s\n" "  ------" "---" "---- " "----" "---- "
			printf "%-10s | %-11s %8s | %-11s %8s\n" "Read" "${DISK_RESULTS[DISK_COUNT*6+1]}" "(${DISK_RESULTS[DISK_COUNT*6+4]})" "${DISK_RESULTS[(DISK_COUNT+1)*6+1]}" "(${DISK_RESULTS[(DISK_COUNT+1)*6+4]})"
			printf "%-10s | %-11s %8s | %-11s %8s\n" "Write" "${DISK_RESULTS[DISK_COUNT*6+2]}" "(${DISK_RESULTS[DISK_COUNT*6+5]})" "${DISK_RESULTS[(DISK_COUNT+1)*6+2]}" "(${DISK_RESULTS[(DISK_COUNT+1)*6+5]})"
			printf "%-10s | %-11s %8s | %-11s %8s\n" "Total" "${DISK_RESULTS[DISK_COUNT*6]}" "(${DISK_RESULTS[DISK_COUNT*6+3]})" "${DISK_RESULTS[(DISK_COUNT+1)*6]}" "(${DISK_RESULTS[(DISK_COUNT+1)*6+3]})"
			if [ ! -z $JSON ]; then
				JSON_RESULT+='{"bs":"'${BLOCK_SIZES[DISK_COUNT]}'","speed_r":'${DISK_RESULTS_RAW[DISK_COUNT*6+1]}',"iops_r":'${DISK_RESULTS_RAW[DISK_COUNT*6+4]}
				JSON_RESULT+=',"speed_w":'${DISK_RESULTS_RAW[DISK_COUNT*6+2]}',"iops_w":'${DISK_RESULTS_RAW[DISK_COUNT*6+5]}',"speed_rw":'${DISK_RESULTS_RAW[DISK_COUNT*6]}
				JSON_RESULT+=',"iops_rw":'${DISK_RESULTS_RAW[DISK_COUNT*6+3]}',"speed_units":"KBps"},'
				JSON_RESULT+='{"bs":"'${BLOCK_SIZES[DISK_COUNT+1]}'","speed_r":'${DISK_RESULTS_RAW[(DISK_COUNT+1)*6+1]}',"iops_r":'${DISK_RESULTS_RAW[(DISK_COUNT+1)*6+4]}
				JSON_RESULT+=',"speed_w":'${DISK_RESULTS_RAW[(DISK_COUNT+1)*6+2]}',"iops_w":'${DISK_RESULTS_RAW[(DISK_COUNT+1)*6+5]}',"speed_rw":'${DISK_RESULTS_RAW[(DISK_COUNT+1)*6]}
				JSON_RESULT+=',"iops_rw":'${DISK_RESULTS_RAW[(DISK_COUNT+1)*6+3]}',"speed_units":"KBps"},'
			fi
			DISK_COUNT=$(expr $DISK_COUNT + 2)
		done
		[[ ! -z $JSON ]] && JSON_RESULT=${JSON_RESULT::${#JSON_RESULT}-1} && JSON_RESULT+=']'
	fi
fi
speed_test() {
    local nodeName="$2"
    [ -z "$1" ] && ./speedtest-cli/speedtest --progress=no --accept-license --accept-gdpr > ./speedtest-cli/speedtest.log 2>&1 || \
    ./speedtest-cli/speedtest --progress=no --server-id=$1 --accept-license --accept-gdpr > ./speedtest-cli/speedtest.log 2>&1
    if [ $? -eq 0 ]; then
        local dl_speed=$(awk '/Download/{print $3" "$4}' ./speedtest-cli/speedtest.log)
        local up_speed=$(awk '/Upload/{print $3" "$4}' ./speedtest-cli/speedtest.log)
        local latency=$(awk '/Latency/{print $2" "$3}' ./speedtest-cli/speedtest.log)
        if [[ -n "${dl_speed}" && -n "${up_speed}" && -n "${latency}" ]]; then
            printf "\033[0;33m%-18s\033[0;32m%-18s\033[0;31m%-20s\033[0;36m%-12s\033[0m\n" " ${nodeName}" "${up_speed}" "${dl_speed}" "${latency}"
        fi
    fi
}

speed() {
    speed_test '' 'Speedtest.net'
    speed_test '21541' 'Los Angeles, US'
    speed_test '43860' 'Dallas, US'
    speed_test '24215' 'Paris, FR'
    speed_test '28922' 'Amsterdam, NL'
    speed_test '27594' 'Guangzhou, CN'
    speed_test '32155' 'Hongkong, CN'
    speed_test '7311'  'Singapore, SG'
    speed_test '21569' 'Tokyo, JP'
    speed_test '17758' 'VNPT-HCM, VN'
    speed_test '17757' 'VNPT-HN, VN'
    speed_test '2515' 'FPT-HCM, VN'
    speed_test '2552' 'FPT-HN, VN'
    speed_test '26853' 'Viettel-HCM, VN'
    speed_test '9903' 'Viettel-HN, VN'
    speed_test '27601' 'Viettel-DN, VN'
}

io_test() {
    (LANG=C dd if=/dev/zero of=benchtest_$$ bs=512k count=$1 conv=fdatasync && rm -f benchtest_$$ ) 2>&1 | awk -F, '{io=$NF} END { print io}' | sed 's/^[ \t]*//;s/[ \t]*$//'
}

calc_size() {
    local raw=$1
    local total_size=0
    local num=1
    local unit="KB"
    if ! [[ ${raw} =~ ^[0-9]+$ ]] ; then
        echo ""
        return
    fi
    if [ "${raw}" -ge 1073741824 ]; then
        num=1073741824
        unit="TB"
    elif [ "${raw}" -ge 1048576 ]; then
        num=1048576
        unit="GB"
    elif [ "${raw}" -ge 1024 ]; then
        num=1024
        unit="MB"
    elif [ "${raw}" -eq 0 ]; then
        echo "${total_size}"
        return
    fi
    total_size=$( awk 'BEGIN{printf "%.1f", '$raw' / '$num'}' )
    echo "${total_size} ${unit}"
}

check_virt(){
    _exists "dmesg" && virtualx="$(dmesg 2>/dev/null)"
    if _exists "dmidecode"; then
        sys_manu="$(dmidecode -s system-manufacturer 2>/dev/null)"
        sys_product="$(dmidecode -s system-product-name 2>/dev/null)"
        sys_ver="$(dmidecode -s system-version 2>/dev/null)"
    else
        sys_manu=""
        sys_product=""
        sys_ver=""
    fi
    if   grep -qa docker /proc/1/cgroup; then
        virt="Docker"
    elif grep -qa lxc /proc/1/cgroup; then
        virt="LXC"
    elif grep -qa container=lxc /proc/1/environ; then
        virt="LXC"
    elif [[ -f /proc/user_beancounters ]]; then
        virt="OpenVZ"
    elif [[ "${virtualx}" == *kvm-clock* ]]; then
        virt="KVM"
    elif [[ "${sys_product}" == *KVM* ]]; then
        virt="KVM"
    elif [[ "${cname}" == *KVM* ]]; then
        virt="KVM"
    elif [[ "${cname}" == *QEMU* ]]; then
        virt="KVM"
    elif [[ "${virtualx}" == *"VMware Virtual Platform"* ]]; then
        virt="VMware"
    elif [[ "${sys_product}" == *"VMware Virtual Platform"* ]]; then
        virt="VMware"
    elif [[ "${virtualx}" == *"Parallels Software International"* ]]; then
        virt="Parallels"
    elif [[ "${virtualx}" == *VirtualBox* ]]; then
        virt="VirtualBox"
    elif [[ -e /proc/xen ]]; then
        if grep -q "control_d" "/proc/xen/capabilities" 2>/dev/null; then
            virt="Xen-Dom0"
        else
            virt="Xen-DomU"
        fi
    elif [ -f "/sys/hypervisor/type" ] && grep -q "xen" "/sys/hypervisor/type"; then
        virt="Xen"
    elif [[ "${sys_manu}" == *"Microsoft Corporation"* ]]; then
        if [[ "${sys_product}" == *"Virtual Machine"* ]]; then
            if [[ "${sys_ver}" == *"7.0"* || "${sys_ver}" == *"Hyper-V" ]]; then
                virt="Hyper-V"
            else
                virt="Microsoft Virtual Machine"
            fi
        fi
    else
        virt="Dedicated"
    fi
}

ipv4_info() {
    local org="$(wget -q -T10 -O- ipinfo.io/org)"
    local city="$(wget -q -T10 -O- ipinfo.io/city)"
    local country="$(wget -q -T10 -O- ipinfo.io/country)"
    local region="$(wget -q -T10 -O- ipinfo.io/region)"
    if [[ -n "$org" ]]; then
        echo " Organization       : $(_blue "$org")"
    fi
    if [[ -n "$city" && -n "country" ]]; then
        echo " Location           : $(_blue "$city / $country")"
    fi
    if [[ -n "$region" ]]; then
        echo " Region             : $(_yellow "$region")"
    fi
    if [[ -z "$org" ]]; then
        echo " Region             : $(_red "No ISP detected")"
    fi
}

install_speedtest() {
    if [ ! -e "./speedtest-cli/speedtest" ]; then
        sys_bit=""
        local sysarch="$(uname -m)"
        if [ "${sysarch}" = "unknown" ] || [ "${sysarch}" = "" ]; then
            local sysarch="$(arch)"
        fi
        if [ "${sysarch}" = "x86_64" ]; then
            sys_bit="x86_64"
        fi
        if [ "${sysarch}" = "i386" ] || [ "${sysarch}" = "i686" ]; then
            sys_bit="i386"
        fi
        if [ "${sysarch}" = "armv8" ] || [ "${sysarch}" = "armv8l" ] || [ "${sysarch}" = "aarch64" ] || [ "${sysarch}" = "arm64" ]; then
            sys_bit="aarch64"
        fi
        if [ "${sysarch}" = "armv7" ] || [ "${sysarch}" = "armv7l" ]; then
            sys_bit="armhf"
        fi
        if [ "${sysarch}" = "armv6" ]; then
            sys_bit="armel"
        fi
        [ -z "${sys_bit}" ] && _red "Error: Unsupported system architecture (${sysarch}).\n" && exit 1
        url1="https://install.speedtest.net/app/cli/ookla-speedtest-1.1.1-linux-${sys_bit}.tgz"
        url2="https://dl.lamp.sh/files/ookla-speedtest-1.1.1-linux-${sys_bit}.tgz"
        wget --no-check-certificate -q -T10 -O speedtest.tgz ${url1}
        if [ $? -ne 0 ]; then
            wget --no-check-certificate -q -T10 -O speedtest.tgz ${url2}
            [ $? -ne 0 ] && _red "Error: Failed to download speedtest-cli.\n" && exit 1
        fi
        mkdir -p speedtest-cli && tar zxf speedtest.tgz -C ./speedtest-cli && chmod +x ./speedtest-cli/speedtest
        rm -f speedtest.tgz
    fi
    printf "%-18s%-18s%-20s%-12s\n" " Node Name" "Upload Speed" "Download Speed" "Latency"
}

print_intro() {
    echo "-------------------- A Bench.sh Script By Teddysun -------------------"
    echo " Version            : $(_green v2023-06-10)"
    echo " Usage              : $(_red "wget -qO- https://raw.githubusercontent.com/wpbai/bench/main/bench-vietnam.sh | bash")"
}

# Get System information
get_system_info() {
    cname=$( awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//' )
    cores=$( awk -F: '/processor/ {core++} END {print core}' /proc/cpuinfo )
    freq=$( awk -F'[ :]' '/cpu MHz/ {print $4;exit}' /proc/cpuinfo )
    ccache=$( awk -F: '/cache size/ {cache=$2} END {print cache}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//' )
    cpu_aes=$( grep -i 'aes' /proc/cpuinfo )
    cpu_virt=$( grep -Ei 'vmx|svm' /proc/cpuinfo )
    tram=$( LANG=C; free | awk '/Mem/ {print $2}' )
    tram=$( calc_size $tram )
    uram=$( LANG=C; free | awk '/Mem/ {print $3}' )
    uram=$( calc_size $uram )
    swap=$( LANG=C; free | awk '/Swap/ {print $2}' )
    swap=$( calc_size $swap )
    uswap=$( LANG=C; free | awk '/Swap/ {print $3}' )
    uswap=$( calc_size $uswap )
    up=$( awk '{a=$1/86400;b=($1%86400)/3600;c=($1%3600)/60} {printf("%d days, %d hour %d min\n",a,b,c)}' /proc/uptime )
    if _exists "w"; then
        load=$( LANG=C; w | head -1 | awk -F'load average:' '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//' )
    elif _exists "uptime"; then
        load=$( LANG=C; uptime | head -1 | awk -F'load average:' '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//' )
    fi
    opsy=$( get_opsy )
    arch=$( uname -m )
    if _exists "getconf"; then
        lbit=$( getconf LONG_BIT )
    else
        echo ${arch} | grep -q "64" && lbit="64" || lbit="32"
    fi
    kern=$( uname -r )
    disk_total_size=$( LANG=C; df -t simfs -t ext2 -t ext3 -t ext4 -t btrfs -t xfs -t vfat -t ntfs -t swap --total 2>/dev/null | grep total | awk '{ print $2 }' )
    disk_total_size=$( calc_size $disk_total_size )
    disk_used_size=$( LANG=C; df -t simfs -t ext2 -t ext3 -t ext4 -t btrfs -t xfs -t vfat -t ntfs -t swap --total 2>/dev/null | grep total | awk '{ print $3 }' )
    disk_used_size=$( calc_size $disk_used_size )
    tcpctrl=$( sysctl net.ipv4.tcp_congestion_control | awk -F ' ' '{print $3}' )
}
# Print System information
print_system_info() {
    if [ -n "$cname" ]; then
        echo " CPU Model          : $(_blue "$cname")"
    else
        echo " CPU Model          : $(_blue "CPU model not detected")"
    fi
    if [ -n "$freq" ]; then
        echo " CPU Cores          : $(_blue "$cores @ $freq MHz")"
    else
        echo " CPU Cores          : $(_blue "$cores")"
    fi
    if [ -n "$ccache" ]; then
        echo " CPU Cache          : $(_blue "$ccache")"
    fi
    if [ -n "$cpu_aes" ]; then
        echo " AES-NI             : $(_green "Enabled")"
    else
        echo " AES-NI             : $(_red "Disabled")"
    fi
    if [ -n "$cpu_virt" ]; then
        echo " VM-x/AMD-V         : $(_green "Enabled")"
    else
        echo " VM-x/AMD-V         : $(_red "Disabled")"
    fi
    echo " Total Disk         : $(_yellow "$disk_total_size") $(_blue "($disk_used_size Used)")"
    echo " Total Mem          : $(_yellow "$tram") $(_blue "($uram Used)")"
    if [ "$swap" != "0" ]; then
        echo " Total Swap         : $(_blue "$swap ($uswap Used)")"
    fi
    echo " System uptime      : $(_blue "$up")"
    echo " Load average       : $(_blue "$load")"
    echo " OS                 : $(_blue "$opsy")"
    echo " Arch               : $(_blue "$arch ($lbit Bit)")"
    echo " Kernel             : $(_blue "$kern")"
    echo " TCP CC             : $(_yellow "$tcpctrl")"
    echo " Virtualization     : $(_blue "$virt")"
    echo " IPv4/IPv6          : $online"
}

print_io_test() {
    freespace=$( df -m . | awk 'NR==2 {print $4}' )
    if [ -z "${freespace}" ]; then
        freespace=$( df -m . | awk 'NR==3 {print $3}' )
    fi
    if [ ${freespace} -gt 1024 ]; then
        writemb=2048
        io1=$( io_test ${writemb} )
        echo " I/O Speed(1st run) : $(_yellow "$io1")"
        io2=$( io_test ${writemb} )
        echo " I/O Speed(2nd run) : $(_yellow "$io2")"
        io3=$( io_test ${writemb} )
        echo " I/O Speed(3rd run) : $(_yellow "$io3")"
        ioraw1=$( echo $io1 | awk 'NR==1 {print $1}' )
        [ "`echo $io1 | awk 'NR==1 {print $2}'`" == "GB/s" ] && ioraw1=$( awk 'BEGIN{print '$ioraw1' * 1024}' )
        ioraw2=$( echo $io2 | awk 'NR==1 {print $1}' )
        [ "`echo $io2 | awk 'NR==1 {print $2}'`" == "GB/s" ] && ioraw2=$( awk 'BEGIN{print '$ioraw2' * 1024}' )
        ioraw3=$( echo $io3 | awk 'NR==1 {print $1}' )
        [ "`echo $io3 | awk 'NR==1 {print $2}'`" == "GB/s" ] && ioraw3=$( awk 'BEGIN{print '$ioraw3' * 1024}' )
        ioall=$( awk 'BEGIN{print '$ioraw1' + '$ioraw2' + '$ioraw3'}' )
        ioavg=$( awk 'BEGIN{printf "%.1f", '$ioall' / 3}' )
        echo " I/O Speed(average) : $(_yellow "$ioavg MB/s")"
    else
        echo " $(_red "Not enough space for I/O Speed test!")"
    fi
}

print_end_time() {
    end_time=$(date +%s)
    time=$(( ${end_time} - ${start_time} ))
    if [ ${time} -gt 60 ]; then
        min=$(expr $time / 60)
        sec=$(expr $time % 60)
        echo " Finished in        : ${min} min ${sec} sec"
    else
        echo " Finished in        : ${time} sec"
    fi
    date_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo " Timestamp          : $date_time"
}

! _exists "wget" && _red "Error: wget command not found.\n" && exit 1
! _exists "free" && _red "Error: free command not found.\n" && exit 1
# check for curl/wget
command -v curl >/dev/null 2>&1 && local_curl=true || unset local_curl
# test if the host has IPv4/IPv6 connectivity
[[ ! -z ${local_curl} ]] && ip_check_cmd="curl -s -m 4" || ip_check_cmd="wget -qO- -T 4"
ipv4_check=$((ping -4 -c 1 -W 4 ipv4.google.com >/dev/null 2>&1 && echo true) || ${ip_check_cmd} -4 icanhazip.com 2> /dev/null)
ipv6_check=$((ping -6 -c 1 -W 4 ipv6.google.com >/dev/null 2>&1 && echo true) || ${ip_check_cmd} -6 icanhazip.com 2> /dev/null)
if [[ -z "$ipv4_check" && -z "$ipv6_check" ]]; then
    _yellow "Warning: Both IPv4 and IPv6 connectivity were not detected.\n"
fi
[[ -z "$ipv4_check" ]] && online="$(_red "Offline")" || online="$(_green "Online")"
[[ -z "$ipv6_check" ]] && online+=" / $(_red "Offline")" || online+=" / $(_green "Online")"
start_time=$(date +%s)
get_system_info
check_virt
clear
print_intro
next
print_system_info
ipv4_info
next
print_io_test
next
install_speedtest && speed && rm -fr speedtest-cli
next
print_end_time
next
