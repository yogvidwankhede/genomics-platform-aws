#!/bin/bash
# Same steps as the Batch launch-template user-data, run inside an amazonlinux:2023 container
# for local testing. Expects /w/awscli.zip and an empty /opt/aws-cli mount.
set -euo pipefail
dnf -q -y install unzip >/dev/null 2>&1
unzip -q /w/awscli.zip -d /tmp/x
/tmp/x/aws/install --install-dir /opt/aws-cli --bin-dir /opt/aws-cli/bin >/dev/null
mkdir -p /opt/aws-cli/lib
cp -L /usr/lib64/libz.so.1 /opt/aws-cli/lib/
mv /opt/aws-cli/bin/aws /opt/aws-cli/bin/aws.real
printf '%s\n' '#!/bin/sh' 'LD_LIBRARY_PATH=/opt/aws-cli/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} exec /opt/aws-cli/bin/aws.real "$@"' > /opt/aws-cli/bin/aws
chmod 0755 /opt/aws-cli/bin/aws
