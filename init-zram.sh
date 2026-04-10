####################################################################################
# If not stated otherwise in this file or this component's Licenses.txt file the
# following copyright and licenses apply:
#
#  Copyright 2018 RDK Management
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##################################################################################
. /etc/include.properties
. /etc/device.properties

MEMSWAP_LOGFILE="${LOG_PATH}/memswap.log"

echo_t() {
    echo "$(date +"%y%m%d-%T.%6N") $1" >>$MEMSWAP_LOGFILE
}

# Wait for the DM system to come up
dmIsUp=1
while [ "x$dmIsUp" != "x0" ]; do
    dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.MEMSWAP.Enable | grep value
    dmIsUp=$?
    sleep 10
done

# Check if MEMSWAP is enabled by RFC, exit if not enabled
MEMSWAP_RFC_ENABLE=$(dmcli eRT retv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.MEMSWAP.Enable)
if [ "x$MEMSWAP_RFC_ENABLE" != "xtrue" ]; then
    echo_t "MEMSWAP is disabled"
    exit 1
fi

# Load ZRAM module with one block device for SWAP
modprobe zram num_devices=1

# Configure the disk size
MEMSWAP_DISK_SIZE=$(dmcli eRT retv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.MEMSWAP.DiskSize)
echo "${MEMSWAP_DISK_SIZE}M" >/sys/block/zram0/disksize
echo_t "MEMSWAP disk size set to ${MEMSWAP_DISK_SIZE}M"

# Configure the system swappiness
MEMSWAP_TUNABLES_SWAPPINESS=$(dmcli eRT retv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.MEMSWAP.Tunables.Swappiness)
sysctl -w vm.swappiness="$MEMSWAP_TUNABLES_SWAPPINESS"
echo_t "System swappiness set to ${MEMSWAP_TUNABLES_SWAPPINESS}"

# Configure the system watermark scale factor
MEMSWAP_TUNABLES_WATERMARK_SCALE_FACTOR=$(dmcli eRT retv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.MEMSWAP.Tunables.WatermarkScaleFactor)
sysctl -w vm.watermark_scale_factor="$MEMSWAP_TUNABLES_WATERMARK_SCALE_FACTOR"
echo_t "System watermark scale factor set to ${MEMSWAP_TUNABLES_WATERMARK_SCALE_FACTOR}"

# Configure the system page cluster for SWAP
MEMSWAP_TUNABLES_PAGE_CLUSTER=$(dmcli eRT retv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.MEMSWAP.Tunables.PageCluster)
sysctl -w vm.page-cluster="$MEMSWAP_TUNABLES_PAGE_CLUSTER"
echo_t "System page cluster for SWAP set to ${MEMSWAP_TUNABLES_PAGE_CLUSTER}"

# Enable the ZRAM SWAP device
mkswap /dev/zram0
swapon /dev/zram0
