#!/bin/bash

# Requires at least 300GB of free disk space on the main partition for the dataset, intermediate files, and SigLens data.

echo "Install prerequisites"
sudo apt-get install -y git golang

echo "Get and build SigLens"
git clone https://github.com/siglens/siglens.git --branch 1.0.54
cd siglens
go mod tidy
go build -o siglens cmd/siglens/main.go
./siglens &> siglens.out &
cd ..

echo "Download and unzip dataset"
sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.json.gz'
pigz -d -f hits.json.gz

echo "Load data into SigLens, this can take a few hours"
echo -n "Load time: "
command time -f '%e' python3 send_datawithactionline.py

echo "Run queries"
./run.sh
