#!/bin/sh
#
# THIS IS NOT THE BUILD SCRIPT FOR SOLO5.
#
# This script is used for automated builds with surf-build and Travis CI.
# See https://github.com/Solo5/solo5-ci for details.
#
if type gmake >/dev/null 2>&1; then
    MAKE=gmake
else
    MAKE=make
fi

message()
{
    printf %80s\\n | tr " " "\*"
    echo "$@"
    printf %80s\\n | tr " " "\*"
}

do_info()
{
    message "System information:"
    uname -a
    echo "Compiler version:"
    cc --version
    echo "Compiler version detail:"
    cc -v
}

try()
{
    if ( eval "$@" ); then
        :
    else
        echo "FAILURE: '$@' failed: Status: $?"
        exit 1
    fi
}

do_basic()
{
    message "Starting build."
    try ./configure.sh
    try ${MAKE}
    # Some CIs can now run tests, so do that.
    if [ -n "${SURF_RUN_TESTS}" ]; then
        message "Running tests:"
        # XXX grub-bhyve is unstable under nested virt, so don't run the
        # virtio tests on FreeBSD.
        if [ "$(uname -s)" = "FreeBSD" ]; then
            echo CONFIG_VIRTIO= >>Makeconf
        fi
        try ${SURF_SUDO} tests/setup-tests.sh
        try ${SURF_SUDO} tests/run-tests.sh
        # On Linux x86_64 Debian VMs only, also test solo5-virtio-mkimage.
        # Specifically don't run this on Ubuntu (Travis) as their syslinux
        # package is broken and incomplete. The following seems as good a way
        # as any to tell we're on actual Debian as opposed to Ubuntu.
        if gcc --version | grep -q Debian; then
            if [ "$(uname -s)" = "Linux" -a "$(uname -m)" = "x86_64" ]; then
                message "Testing solo5-virtio-mkimage.sh:"
                try scripts/virtio-mkimage/solo5-virtio-mkimage.sh \
                    test.img tests/test_hello/test_hello.virtio
                # XXX Can't use try() here due to 83 == OK
                timeout 10s \
                    qemu-system-x86_64 -machine q35 \
                    -display none -serial file:serial.out \
                    -drive file=test.img,if=virtio,format=raw \
                    -device isa-debug-exit
                if grep -q 'solo5_exit(0) called' serial.out; then
                    echo "SUCCESS"
                    rm -f test.img serial.out
                else
                    echo "FAILURE. Log follows:"
                    cat serial.out
                    exit 1
                fi
            fi
        fi
    fi
    message "Testing 'make distrib'."
    try ${MAKE} distrib
    message "Testing tools only build."
    try ${MAKE} distclean
    try ./configure.sh --only-tools
    try ${MAKE}
    try ${SURF_SUDO} ${MAKE} install-tools
}

do_e2e()
{
    message "Starting E2E tests."
    (
    # Force the package universe used by the E2E tests to use this
    # checked out copy of Solo5.
    u_SOLO5=./tests/e2e-mirage-solo5/universe/solo5-bindings-hvt
    set -xe
    rm -f ${u_SOLO5}/local ${u_SOLO5}/master ${u_SOLO5}/release
    ln -s $(readlink -f .) ${u_SOLO5}/local
    # Hack around the fact that OPAM switches are not relocatable by running out
    # of the fixed path '/tmp/e2e'. This allows us to make use of the base
    # switch cache which has been pre-populated on the CI VM.
    mkdir -p /tmp/e2e
    # /tmp/e2e can't be a symlink for ... various reasons...
    ${SURF_SUDO} mount --bind $(readlink -f ./tests/e2e-mirage-solo5) /tmp/e2e
    mkdir -p /tmp/e2e/run/switch
    ln -s /home/build/cache/switch.tar.gz /tmp/e2e/run/switch.tar.gz
    ) || exit 1
    cd /tmp/e2e
    try $(opam env) dune exec bin/main.exe
}

do_info
case "${SURF_BUILD_TYPE}" in
    basic)
        do_basic
        ;;
    e2e)
        do_e2e
        ;;
    *)
        echo "ERROR: SURF_BUILD_TYPE not set"
        exit 1
        ;;
esac

message "Success!"
# NOTE: Failure exit status is returned in try(), if we got here then the build
# NOTE: completed.
