#!/bin/bash

# Function to calculate IBC denom
calculate_ibc_denom() {
    local path=$1
    local base_denom=$2

    # Combine path and base denom
    local combined="${path}/${base_denom}"

    # Compute the SHA256 hash and convert to uppercase
    local hash=$(echo -n "$combined" | sha256sum | awk '{print $1}' | tr 'a-f' 'A-F')

    # Construct the IBC denom
    echo "ibc/${hash}"
}

# Check for required inputs
if [ $# -ne 2 ]; then
    echo "Usage: $0 <path> <base_denom>"
    echo "Example: $0 transfer/channel-0 uatom"
    exit 1
fi

# Read inputs
path=$1
base_denom=$2

# Calculate and display the IBC denom
ibc_denom=$(calculate_ibc_denom "$path" "$base_denom")
echo "IBC Denom: $ibc_denom"

