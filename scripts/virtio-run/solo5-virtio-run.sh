#!/bin/sh
# Copyright (c) 2015-2019 Contributors as noted in the AUTHORS file
#
# This file is part of Solo5, a sandboxed execution environment.
#
# Permission to use, copy, modify, and/or distribute this software
# for any purpose with or without fee is hereby granted, provided
# that the above copyright notice and this permission notice appear
# in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
# WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
# AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
# CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
# OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
# NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
# CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

usage ()
{
    cat <<EOM 1>&2
Usage: solo5-virtio-run [ OPTIONS ] UNIKERNEL [ -- ] [ ARGUMENTS ... ]

Launch the Solo5 UNIKERNEL (virtio target). Unikernel output is sent to stdout.

Options:
    -d DISK: Attach virtio-blk device with DISK image file.

    -m MEM: Start guest with MEM megabytes of memory (default is 128).

    -n NETIF: Attach virtio-net device with NETIF tap interface.

    -q: Quiet mode. Don't print hypervisor incantations.

    -H HV: Use hypervisor HV (default is "best available").
EOM
    exit 1
}

die ()
{
    echo solo5-virtio-run: error: "$@" 1>&2
    exit 1
}

hv_addargs ()
{
    if [ -z "${HVCMD}" ]; then
        HVCMD="$@"
    else
        HVCMD="${HVCMD} $@"
    fi
}

is_quiet ()
{
    [ -n "${QUIET}" ]
}

qemu_add_device ()
{
    DEVICE=$1
    PCI_SLOT=$2
    PS_HEX=$(printf "%x" ${PCI_SLOT})

    OLDIFS=$IFS
    IFS=:
    set -- ${D}
    IFS=$OLDIFS

    TYPE=$1
    NAME="$2"
    shift; shift

    case $TYPE in
    BLK)
        hv_addargs -drive id=drive${PCI_SLOT},file="${NAME}",if=none,format=raw
        hv_addargs -device virtio-blk,drive=drive${PCI_SLOT},addr=0x${PS_HEX},bus=pci.0
        ;;
    NET)
        hv_addargs -device virtio-net,netdev=n${PCI_SLOT},addr=0x${PS_HEX},bus=pci.0
        hv_addargs -netdev tap,id=n${PCI_SLOT},ifname="${NAME}",script=no,downscript=no
        ;;
    *)
        die "Unknown device type"
        ;;
    esac
}

bhyve_add_device ()
{
    DEVICE=$1
    PCI_SLOT=$2

    OLDIFS=$IFS
    IFS=:
    set -- ${D}
    IFS=$OLDIFS

    TYPE=$1
    NAME="$2"
    shift; shift

    case $TYPE in
    BLK)
        hv_addargs -s ${PCI_SLOT}:0,virtio-blk,"${NAME}"
        ;;
    NET)
        hv_addargs -s ${PCI_SLOT}:0,virtio-net,"${NAME}"
        ;;
    *)
        die "Unknown device type"
        ;;
    esac
}

# Parse command line arguments.
ARGS=$(getopt d:m:n:qH: $*)
[ $? -ne 0 ] && usage
set -- $ARGS
MEM=128
HV=best
DEVICES=
QUIET=
while true; do
    case "$1" in
    -d)
        BLKIMG=$(readlink -f $2)
        [ -f ${BLKIMG} ] || die "not found: ${BLKIMG}"
        DEVICES="${DEVICES} BLK:${BLKIMG}"
        shift; shift
        ;;
    -m)
        MEM="$2"
        shift; shift
        ;;
    -n)
        NETIF="$2"
        # Check dependencies
        type ip >/dev/null 2>&1 ||
            type ifconfig >/dev/null 2>&1 ||
            die "need ip or ifconfig installed"
        ip a show ${NETIF} >/dev/null 2>&1 ||
            ifconfig ${NETIF} >/dev/null 2>&1 ||
            die "no such network interface: ${NETIF}"
    	DEVICES="${DEVICES} NET:${NETIF}"
        shift; shift
        ;;
    -q)
        QUIET=1
        shift
        ;;
    -H)
        HV="$2"
        shift; shift
        ;;
    --)
        shift; break
        ;;
    esac
done
[ $# -lt 1 ] && usage

UNIKERNEL=$(readlink -f $1)
[ -n "${UNIKERNEL}" -a -f "${UNIKERNEL}" ] || die "not found: $1}"
shift
VMNAME=vm$$

if [ "${HV}" = "best" ]; then
    SYS=$(uname -s)
    case ${SYS} in
    Linux)
        if [ -c /dev/kvm -a -w /dev/kvm ]; then
            HV=kvm
        else
            HV=qemu
        fi
        ;;
    FreeBSD)
        # XXX How to detect if bhyve is available on this machine?
        HV=bhyve
        [ $(id -u) -eq 0 ] || die "Root privileges required for bhyve"
        type grub-bhyve >/dev/null 2>&1 \
            || die "Please install sysutils/grub2-bhyve from ports"
        ;;
    *)
        die "unsupported os: ${SYS}"
        ;;
    esac
fi

case ${HV} in
kvm|qemu)
    hv_addargs qemu-system-x86_64
    case ${HV} in
    kvm)
        hv_addargs -cpu host -enable-kvm
        ;;
    qemu)
        hv_addargs -cpu Westmere
        ;;
    esac
    hv_addargs -m ${MEM}

    # Kill all default devices provided by QEMU, we don't need them.
    hv_addargs -nodefaults -machine acpi=off

    # Console. We could use just "-nograhic -vga none", however that MUXes the
    # QEMU monitor on stdio which requires ^Ax to exit. This makes things look
    # more like a normal process (quit with ^C), consistent with bhyve and
    # solo5-hvt.
    hv_addargs -display none -serial stdio

    # Slots 0 and 1 are already used.
    PCI_SLOT=2

    for D in ${DEVICES}; do
        qemu_add_device $D ${PCI_SLOT}
        # The maximum PCI slot is 31. We don't check this as qemu will fail
        # with a more helpful message.
        PCI_SLOT=$((PCI_SLOT+1))
    done

    # Used by automated tests on QEMU (see kernel/virtio/platform.c).
    hv_addargs -device isa-debug-exit

    hv_addargs -kernel ${UNIKERNEL}

    # QEMU command line parsing is just stupid.
    ARGS=
    if [ "$#" -ge 1 ]; then
        ARGS="$(echo "$@" | sed -e s/,/,,/g)"
        is_quiet || set -x
        exec ${HVCMD} -append "${ARGS}"
    else
        is_quiet || set -x
        exec ${HVCMD}
    fi
    ;;
bhyve)
    # Load the VM using grub-bhyve. Kill stdout as this is normal GRUB output.
    (is_quiet || set -x; \
        printf -- "multiboot ${UNIKERNEL} placeholder %s\nboot\n" "$*" \
        | grub-bhyve -M ${MEM} "${VMNAME}" >/dev/null) \
        || die "Could not initialise VM"

    hv_addargs bhyve
    hv_addargs -u
    hv_addargs -m ${MEM}
    hv_addargs -H -s 0:0,hostbridge -s 1:0,lpc

    # Console. Bhyve insists on talking to a TTY so fake one in a way that we
    # can redirect output to a file (see below).
    TTYA=/dev/nmdm$$A
    TTYB=/dev/nmdm$$B
    hv_addargs -l com1,${TTYB}
    

    # Slots 0 and 1 are already used.
    PCI_SLOT=2

    for D in ${DEVICES}; do
        bhyve_add_device $D ${PCI_SLOT}
        # The maximum PCI slot is 31. We don't check this as bhyve will fail
        # with a more helpful message.
        PCI_SLOT=$((PCI_SLOT+1))
    done

    hv_addargs ${VMNAME}

    # Fake a console using nmdm(4). Open 'A' end first and keep it open, then
    # set some sane TTY parameters and launch bhyve on the 'B' end.
    # Bhyve will respond to interactive SIGINT correctly, the cat and VM itself
    # are cleaned up below.
    # XXX Can occasionally leak /dev/nmdm devices, oh well ...
    # sleep a bit to ensure that cat has opened /dev/nmdm before stty
    cat ${TTYA} &
    sleep 0.2
    CAT=$!
    cleanup ()
    {
        kill ${CAT} >/dev/null 2>&1
        bhyvectl --destroy --vm=${VMNAME} >/dev/null 2>&1
    }
    trap cleanup 0 INT TERM
    stty -f ${TTYB} >/dev/null
    stty -f ${TTYA} 115200 igncr

    # Can't do exec here since we need to clean up the 'cat' process.
    ( is_quiet || set -x; ${HVCMD} )
    exit $?
    ;;
best)
    die "Could not determine hypervisor, try with -H"
    ;;
*)
    die "Unknown hypervisor: ${HV}"
    ;;
esac
