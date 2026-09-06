#!/bin/bash
# Clones dkosmari/nvidia-340.108-updated, applies its own patch, then applies
# the fixes in this repo's patches/ directory on top, and builds the module.
# Does not install anything by itself -- review the printed `sudo make
# install` command and run it yourself.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${1:-nvidia-340.108-updated}"

if [ ! -d "$WORKDIR" ]; then
    git clone https://github.com/dkosmari/nvidia-340.108-updated.git "$WORKDIR"
fi
cd "$WORKDIR"

if [ ! -f nv-kernel.o_shipped ]; then
    ./apply-patch.sh
fi

for p in "$HERE"/patches/*.patch; do
    echo "==> applying $(basename "$p")"
    patch -p1 --forward -r - < "$p" || {
        echo "Already applied or conflicts with local changes: $(basename "$p")" >&2
    }
done

make

cat <<EOF

Build finished. To install via DKMS:

    cd $WORKDIR
    sudo make install

Then, before loading the driver, make sure nouveau isn't holding the card:

    sudo modprobe -r nouveau
    sudo modprobe nvidia
    sudo nvidia-modprobe
    nvidia-smi
EOF
