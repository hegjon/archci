# devtools ships makepkg.conf.d/x86_64.conf only. archci-worker derives the
# riscv64 one from it at package build time with these substitutions, so the
# port follows devtools' flags: -march=rv64gc -mabi=lp64d (what Arch Linux
# RISC-V builds for), and the x86-only -fcf-protection and
# -mno-omit-leaf-frame-pointer dropped, and -z pack-relative-relocs (DT_RELR),
# which binutils' riscv64 ld does not support. Applied to x86_64.conf and its
# conf.d/*.conf.
s/^CARCH="x86_64"$/CARCH="riscv64"/
s/^CHOST="x86_64-pc-linux-gnu"$/CHOST="riscv64-unknown-linux-gnu"/
s/-march=x86-64[^ ]* -mtune=generic/-march=rv64gc -mabi=lp64d/
s/ -fcf-protection//
s/ -mno-omit-leaf-frame-pointer//
s/^ *-Wl,-z,pack-relative-relocs"$/"/
s/^LIB_DIRS=('lib:usr\/lib' 'lib32:usr\/lib32')$/LIB_DIRS=('lib:usr\/lib')/
