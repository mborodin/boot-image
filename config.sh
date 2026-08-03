#!/bin/bash
#======================================
# Include KIWI functions & variables
#--------------------------------------
test -f /.kconfig && . /.kconfig
test -f /.profile && . /.profile

echo "Configure image: [$kiwi_iname]..."

#======================================
# Enable services
#--------------------------------------
baseService NetworkManager on
baseService sshd on

# The MOK auto-enroll unit is gated by ConditionKernelCommandLine=mokenroll,
# so it's safe to always enable it -- it only fires when the "mokutil"
# boot entry passes that kernel parameter.
baseService mok-enroll on

#======================================
# Permissions for overlay scripts
#--------------------------------------
chmod 755 /usr/local/sbin/mok-enroll.sh

exit 0
