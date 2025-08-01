#!/bin/bash
set -e

# This benchmark should run on Ubuntu 20.04

# Install
ROOT=$(pwd)

if [[ -n "$1" ]]; then
    url="$1"
else
    url='https://apache-doris-releases.oss-accelerate.aliyuncs.com/apache-doris-2.1.7-rc01-bin-x64.tar.gz'
fi
# Download
file_name="$(basename ${url})"
if [[ "$url" == "http"* ]]; then
    if [[ ! -f $file_name ]]; then
        wget --continue --progress=dot:giga ${url}
    else
        echo "$file_name already exists, no need to download."
    fi
fi
dir_name="${file_name/.tar.gz/}"

# Try to stop Doris and remove it first if execute this script multiple times
set +e
"$dir_name"/apache-doris-2.1.7-rc01-bin-x64/fe/bin/stop_fe.sh
"$dir_name"/apache-doris-2.1.7-rc01-bin-x64/be/bin/stop_be.sh
rm -rf "$dir_name"
set -e

# Uncompress
mkdir "$dir_name"
tar zxf "$file_name" -C "$dir_name"
DORIS_HOME="$ROOT/$dir_name/apache-doris-2.1.7-rc01-bin-x64"
export DORIS_HOME

# Install dependencies
sudo apt-get update -y
sudo apt-get install -y openjdk-17-jdk
sudo apt-get install -y mysql-client
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)/"
export PATH=$JAVA_HOME/bin:$PATH

sudo systemctl disable unattended-upgrades
sudo systemctl stop unattended-upgrades

"$DORIS_HOME"/fe/bin/start_fe.sh --daemon

# Start Backend
sudo sysctl -w vm.max_map_count=2000000
ulimit -n 65535
"$DORIS_HOME"/be/bin/start_be.sh --daemon

# Wait for Frontend ready
for _ in {1..300}
do
    fe_version=$(mysql -h127.0.0.1 -P9030 -uroot -e 'show frontends' | cut -f16 | sed -n '2,$p')
    if [[ -n "${fe_version}" ]] && [[ "${fe_version}" != "NULL" ]]; then
        echo "Frontend version: ${fe_version}"
        break
    else
        echo 'Wait for Frontend ready ...'
        sleep 2
    fi
done

# Setup cluster, add Backend to cluster
mysql -h 127.0.0.1 -P9030 -uroot -e "ALTER SYSTEM ADD BACKEND '127.0.0.1:9050' "

# Wait for Backend ready
for _ in {1..300}
do
    be_version=$(mysql -h127.0.0.1 -P9030 -uroot -e 'show backends' | cut -f22 | sed -n '2,$p')
    if [[ -n "${be_version}" ]]; then
        echo "Backend version: ${be_version}"
        break
    else
        echo 'Wait for Backend ready ...'
        sleep 2
    fi
done

echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

# Create Database and table
mysql -h 127.0.0.1 -P9030 -uroot -e "CREATE DATABASE hits"
sleep 5
mysql -h 127.0.0.1 -P9030 -uroot hits <"$ROOT"/create.sql

# Download data
if [[ ! -f hits.tsv.gz ]] && [[ ! -f hits.tsv ]]; then
    sudo apt-get install -y pigz
    wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
    pigz -d -f hits.tsv.gz
fi

# Load data
echo "start loading hits.tsv, estimated to take about 9 minutes ..."
date
START=$(date +%s)
curl --location-trusted \
    -u root: \
    -T "hits.tsv" \
    -H "label:hits" \
    -H "columns: WatchID,JavaEnable,Title,GoodEvent,EventTime,EventDate,CounterID,ClientIP,RegionID,UserID,CounterClass,OS,UserAgent,URL,Referer,IsRefresh,RefererCategoryID,RefererRegionID,URLCategoryID,URLRegionID,ResolutionWidth,ResolutionHeight,ResolutionDepth,FlashMajor,FlashMinor,FlashMinor2,NetMajor,NetMinor,UserAgentMajor,UserAgentMinor,CookieEnable,JavascriptEnable,IsMobile,MobilePhone,MobilePhoneModel,Params,IPNetworkID,TraficSourceID,SearchEngineID,SearchPhrase,AdvEngineID,IsArtifical,WindowClientWidth,WindowClientHeight,ClientTimeZone,ClientEventTime,SilverlightVersion1,SilverlightVersion2,SilverlightVersion3,SilverlightVersion4,PageCharset,CodeVersion,IsLink,IsDownload,IsNotBounce,FUniqID,OriginalURL,HID,IsOldCounter,IsEvent,IsParameter,DontCountHits,WithHash,HitColor,LocalEventTime,Age,Sex,Income,Interests,Robotness,RemoteIP,WindowName,OpenerName,HistoryLength,BrowserLanguage,BrowserCountry,SocialNetwork,SocialAction,HTTPError,SendTiming,DNSTiming,ConnectTiming,ResponseStartTiming,ResponseEndTiming,FetchTiming,SocialSourceNetworkID,SocialSourcePage,ParamPrice,ParamOrderID,ParamCurrency,ParamCurrencyID,OpenstatServiceName,OpenstatCampaignID,OpenstatAdID,OpenstatSourceID,UTMSource,UTMMedium,UTMCampaign,UTMContent,UTMTerm,FromTag,HasGCLID,RefererHash,URLHash,CLID" \
    http://localhost:8030/api/hits/hits/_stream_load
END=$(date +%s)
LOADTIME=$(echo "$END - $START" | bc)
echo "Load time: $LOADTIME"
echo "$LOADTIME" > loadtime

# Dataset contains 99997497 rows, storage size is about 17319588503 bytes
mysql -h 127.0.0.1 -P9030 -uroot hits -e "SELECT count(*) FROM hits"
du -bs "$DORIS_HOME"/be/storage/ | cut -f1 | tee storage_size

echo "Data size: $(cat storage_size)"

./run.sh 2>&1 | tee -a log.txt

cat log.txt |
  grep -P 'rows? in set|Empty set|^ERROR' |
  sed -r -e 's/^ERROR.*$/null/; s/^.*?\((([0-9.]+) min )?([0-9.]+) sec\).*?$/\2 \3/' |
  awk '{ if ($2 != "") { print $1 * 60 + $2 } else { print $1 } }' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
