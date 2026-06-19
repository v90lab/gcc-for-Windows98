#!/bin/bash

# This script is used in the Dockerfile to install apt packages with mirrors.
# It will try multiple mirrors and select the first one that works.

# Usage: ./apt-mirror-selector.sh

set -euo pipefail # Strict mode

opts="-o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"
mirrors="dal.mirrors.clouvider.net archive.ubuntu.com"
ok=""

for host in $mirrors; do
    echo "trying ubuntu mirror: $host"
    cp /etc/apt/sources.list /tmp/sources.list.bak
    sed -i "s|http://archive.ubuntu.com/ubuntu|http://${host}/ubuntu|g; s|http://security.ubuntu.com/ubuntu|http://${host}/ubuntu|g" /etc/apt/sources.list
    rm -rf /var/lib/apt/lists/*
    if apt-get $opts update; then
        ok="$host"
        break
    fi
    cp /tmp/sources.list.bak /etc/apt/sources.list
done

if [ -z "$ok" ]; then
    echo "no usable ubuntu mirror found" >&2
    exit 1
fi

echo "selected ubuntu mirror: $ok"
echo "trying to execute apt install with options: $opts"

apt-get $opts install "$@"
