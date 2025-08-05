#!/bin/bash

TRIES=3
QUERY_NUM=1
echo $1

# Detect available memory on Linux and set a safe limit for DataFusion
MEMORY_LIMIT=""  # Default to no limit
if [ -f /proc/meminfo ]; then
    # Get available memory in KB from /proc/meminfo
    AVAILABLE_KB=$(grep '^MemAvailable:' /proc/meminfo | awk '{print $2}')
    if [ -n "$AVAILABLE_KB" ]; then
        # Convert to GB and use 100% of available memory (rounded down)
        MEMORY_LIMIT_GB=$((AVAILABLE_KB / 1024 / 1024))
        if [ $MEMORY_LIMIT_GB -gt 0 ]; then
            MEMORY_LIMIT="${MEMORY_LIMIT_GB}g"
            echo "Detected ${AVAILABLE_KB}KB available memory, using ${MEMORY_LIMIT} limit for DataFusion"
        fi
    fi
fi
cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    echo "$query" > /tmp/query.sql

    echo -n "["
    for i in $(seq 1 $TRIES); do
        # 1. there will be two query result, one for creating table another for executing the select statement
        # 2. each query contains a "Query took xxx seconds", we just grep these 2 lines
        # 3. use sed to take the second line
        # 4. use awk to take the number we want
        # Build datafusion-cli command with optional memory limit
        DATAFUSION_ARGS="-f create.sql /tmp/query.sql"
        if [ -n "$MEMORY_LIMIT" ]; then
            RES=$(datafusion-cli -m $MEMORY_LIMIT $DATAFUSION_ARGS 2>&1 | grep "Elapsed" |sed -n 2p | awk '{ print $2 }')
        else
            RES=$(datafusion-cli $DATAFUSION_ARGS 2>&1 | grep "Elapsed" |sed -n 2p | awk '{ print $2 }')
        fi
        [[ $RES != "" ]] && \
            echo -n "$RES" || \
            echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "
        echo "${QUERY_NUM},${i},${RES}" >> result.csv
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done
