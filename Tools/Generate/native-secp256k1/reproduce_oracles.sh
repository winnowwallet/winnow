#!/bin/sh
# Optional fixture regeneration; neither C nor Python is a Swift build dependency.
set -eu
if [ "$#" -ne 1 ] || [ -e "$1" ]; then
    echo 'Usage: sh Tools/reproduce_oracles.sh /absolute/path/to/new-scratch-directory' >&2
    exit 2
fi
tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p -- "$1"
oracle_scratch=$(CDPATH= cd -- "$1" && pwd)

fetch_revision() {
    git init -q "$1"
    git -C "$1" remote add origin "$2"
    git -C "$1" fetch --depth 1 origin "$3"
    git -C "$1" checkout --detach FETCH_HEAD
}

fetch_revision "$oracle_scratch/bips" https://github.com/bitcoin/bips.git 927b6de9915c9262615a6399de51b200f81e5aa4
fetch_revision "$oracle_scratch/secp256k1" https://github.com/bitcoin-core/secp256k1.git 1a53f4961f337b4d166c25fce72ef0dc88806618
secp_source="$oracle_scratch/secp256k1"
clang -O2 -DENABLE_MODULE_EXTRAKEYS=1 -I "$secp_source" -I "$secp_source/include" -c "$secp_source/src/secp256k1.c" -o "$oracle_scratch/secp256k1.o"
clang -O2 -I "$secp_source" -c "$secp_source/src/precomputed_ecmult.c" -o "$oracle_scratch/precomputed_ecmult.o"
clang -O2 -I "$secp_source" -c "$secp_source/src/precomputed_ecmult_gen.c" -o "$oracle_scratch/precomputed_ecmult_gen.o"
clang -O2 -Wall -Wextra -Werror -I "$secp_source/include" "$tool_dir/xonly_oracle.c" "$oracle_scratch/secp256k1.o" "$oracle_scratch/precomputed_ecmult.o" "$oracle_scratch/precomputed_ecmult_gen.o" -o "$oracle_scratch/xonly_oracle"
python3 "$tool_dir/generate_vectors.py" "$oracle_scratch/bips" "$secp_source" "$oracle_scratch/xonly_oracle"
