"""What BusyBox's Makefile exports to Kconfig, as this example gives it."""

# BusyBox's tree names no variable; its kconfig, the kernel's of 2.6.2x,
# reads `KERNELVERSION` from the environment for the heading of `.config`
# (`# Busybox version: 1.37.0`), and `KCONFIG_NOTIMESTAMP` keeps the date out
# of it, so that the heading is the four lines the comparison drops. The
# generated repositories are given nothing: the parser of 4.19 reads the
# environment only where a Kconfig names a variable.
BUSYBOX_ENV = {
    "KCONFIG_NOTIMESTAMP": "1",
    "KERNELVERSION": "1.37.0",
}
