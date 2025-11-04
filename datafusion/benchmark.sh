#!/bin/bash

echo "Install Rust"
if command -v rustc &> /dev/null; then
    echo "Rust is already installed: $(rustc --version)"
    export HOME=${HOME:=~}
    source ~/.cargo/env 2>/dev/null || true
else
    echo "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > rust-init.sh
    bash rust-init.sh -y
    export HOME=${HOME:=~}
    source ~/.cargo/env
fi

echo "Install Dependencies"
sudo apt-get update -y
sudo apt-get install -y gcc

echo "Install DataFusion main branch"
if [ -f "/usr/local/bin/datafusion-cli" ]; then
    echo "datafusion-cli already exists in /usr/local/bin, skipping compilation"
    export PATH="/usr/local/bin:$PATH"
    echo "Current version: $(/usr/local/bin/datafusion-cli --version)"
else
    git clone https://github.com/apache/arrow-datafusion.git
    cd arrow-datafusion/
    git checkout 50.0.0
    CARGO_PROFILE_RELEASE_LTO=true RUSTFLAGS="-C codegen-units=1" cargo build --release --package datafusion-cli --bin datafusion-cli
    sudo cp target/release/datafusion-cli /usr/local/bin/
    export PATH="/usr/local/bin:$PATH"
    cd ..
fi

echo "Download benchmark target data, single file"
wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/hits.parquet

echo "Run benchmarks"
./run.sh

echo "Load time: 0"
echo "Data size: $(du -bcs hits.parquet)"
