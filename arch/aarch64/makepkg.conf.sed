# devtools ships makepkg.conf.d/x86_64.conf only. archci-worker-git derives the
# aarch64 one from it at package build time with these substitutions, so the
# port follows devtools' flags (the Arch Linux Ports RFC asks a port to stay
# as close as possible to x86_64's): -march=armv8-a, and the x86-only
# -fcf-protection / -mno-omit-leaf-frame-pointer replaced by
# -mbranch-protection=standard. Applied to x86_64.conf and its conf.d/*.conf.
s/^CARCH="x86_64"$/CARCH="aarch64"/
s/^CHOST="x86_64-pc-linux-gnu"$/CHOST="aarch64-unknown-linux-gnu"/
s/-march=x86-64[^ ]* -mtune=generic/-march=armv8-a/
s/-fcf-protection/-mbranch-protection=standard/
s/ -mno-omit-leaf-frame-pointer//
s/^LIB_DIRS=('lib:usr\/lib' 'lib32:usr\/lib32')$/LIB_DIRS=('lib:usr\/lib')/
