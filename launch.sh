#!/bin/sh

. $AMQ_HOME/bin/configure.sh
. $AMQ_HOME/bin/partitionPV.sh
. /usr/local/dynamic-resources/dynamic_resources.sh

ACTIVEMQ_OPTS="-javaagent:${AMQ_HOME}/jolokia.jar=port=8778,protocol=https,caCert=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt,clientPrincipal=cn=system:master-proxy,useSslClientAuthentication=true,extraClientCheck=true,host=0.0.0.0,discoveryEnabled=false"

MAX_HEAP=`get_heap_size`
if [ -n "$MAX_HEAP" ]; then
  ACTIVEMQ_OPTS="-Xms${MAX_HEAP}m -Xmx${MAX_HEAP}m $ACTIVEMQ_OPTS"
fi

# Make sure that we use /dev/urandom
ACTIVEMQ_OPTS="${ACTIVEMQ_OPTS} -Djava.security.egd=file:/dev/./urandom"

# Add jolokia command line options
cat <<EOF > $AMQ_HOME/bin/env
ACTIVEMQ_OPTS="${ACTIVEMQ_OPTS}"
EOF

echo "Running $JBOSS_IMAGE_NAME image, version $JBOSS_IMAGE_VERSION-$JBOSS_IMAGE_RELEASE"

# Parameters are
# - instance directory
function runServer() {
  # Fix log file
  local instanceDir=$1
  local log_file="$AMQ_HOME/conf/log4j.properties"
  sed -i "s+activemq\.base}/data+activemq.data}+" "$log_file"

  export ACTIVEMQ_DATA="$instanceDir"
  exec "$AMQ_HOME/bin/activemq" console
}

if [ "$AMQ_SPLIT" = "true" ]; then
  DATA_DIR="${AMQ_HOME}/data"
  mkdir -p "${DATA_DIR}"

  partitionPV "${DATA_DIR}" "${AMQ_LOCK_TIMEOUT:-30}"
else
    exec $AMQ_HOME/bin/activemq console
fi
