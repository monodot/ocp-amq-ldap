#!/bin/sh

OPENSHIFT_CONFIG_FILE=$AMQ_HOME/conf/openshift-activemq.xml
CONFIG_FILE=$AMQ_HOME/conf/activemq.xml
OPENSHIFT_LOGIN_FILE=$AMQ_HOME/conf/openshift-login.config
LOGIN_FILE=$AMQ_HOME/conf/login.config
OPENSHIFT_USERS_FILE=$AMQ_HOME/conf/openshift-users.properties
USERS_FILE=$AMQ_HOME/conf/users.properties

# Finds the environment variable  and returns its value if found.
# Otherwise returns the default value if provided.
#
# Arguments:
# $1 env variable name to check
# $2 default value if environemnt variable was not set
function find_env() {
  var=`printenv "$1"`

  # If environment variable exists
  if [ -n "$var" ]; then
    echo $var
  else
    echo $2
  fi
}

function checkViewEndpointsPermission() {
    if [ "${AMQ_MESH_DISCOVERY_TYPE}" = "kube" ]; then
        if [ -n "${AMQ_MESH_SERVICE_NAMESPACE+_}" ] && [ -n "${AMQ_MESH_SERVICE_NAME+_}" ]; then
            endpointsUrl="https://${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}:${KUBERNETES_SERVICE_PORT:-443}/api/v1/namespaces/${AMQ_MESH_SERVICE_NAMESPACE}/endpoints/${AMQ_MESH_SERVICE_NAME}"
            endpointsAuth="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
            endpointsCode=$(curl -s -o /dev/null -w "%{http_code}" -G -k -H "${endpointsAuth}" ${endpointsUrl})
            if [ "${endpointsCode}" = "200" ]; then
                echo "Service account has sufficient permissions to view endpoints in kubernetes (HTTP ${endpointsCode}). Mesh will be available."
            elif [ "${endpointsCode}" = "403" ]; then
                >&2 echo "WARNING: Service account has insufficient permissions to view endpoints in kubernetes (HTTP ${endpointsCode}). Mesh will be unavailable. Please refer to the documentation for configuration."
            else
                >&2 echo "WARNING: Service account unable to test permissions to view endpoints in kubernetes (HTTP ${endpointsCode}). Mesh will be unavailable. Please refer to the documentation for configuration."
            fi
        else
            >&2 echo "WARNING: Environment variables AMQ_MESH_SERVICE_NAMESPACE and AMQ_MESH_SERVICE_NAME both need to be defined when using AMQ_MESH_DISCOVERY_TYPE=\"kube\". Mesh will be unavailable. Please refer to the documentation for configuration."
        fi
    fi
}

function configureMesh() {
  serviceName="${AMQ_MESH_SERVICE_NAME}"
  username="${AMQ_USER}"
  password="${AMQ_PASSWORD}"
  discoveryType="${AMQ_MESH_DISCOVERY_TYPE:-dns}"

  if [ -n "${serviceName}" ] ; then
    networkConnector=""
    if [ -n "${username}" -a -n "${password}" ] ; then
      networkConnector="<networkConnector userName=\"${username}\" password=\"${password}\" uri=\"${discoveryType}://${serviceName}:61616/?transportType=tcp\" messageTTL=\"-1\" consumerTTL=\"1\" />"
    else
      networkConnector="<networkConnector uri=\"${discoveryType}://${serviceName}:61616/?transportType=tcp\" messageTTL=\"-1\" consumerTTL=\"1\" />"
    fi
    sed -i "s|<!-- ##### MESH_CONFIG ##### -->|${networkConnector}|" "$CONFIG_FILE"
  fi
}

function configureAuthentication() {
  username="${AMQ_USER}"
  password="${AMQ_PASSWORD}"

  ldap_host="${LDAP_HOST}"
  ldap_user="${LDAP_USER}"
  ldap_password="${LDAP_PASSWORD}"
  
  if [ -n "${username}" -a -n "${password}" ] ; then
    sed -i "s|##### AUTHENTICATION #####|${username}=${password}|" "${USERS_FILE}"
    authentication="<jaasAuthenticationPlugin configuration=\"activemq\" />"
  elif [ -n "${ldap_host}" -a -n "${ldap_user}" -a -n "${ldap_password}" ]; then
    ldapConfiguration="LdapConfiguration {\n\
    org.apache.activemq.jaas.LDAPLoginModule required \n\
        debug=true \n\
        initialContextFactory=com.sun.jndi.ldap.LdapCtxFactory \n\
        connectionURL=\"ldap://${ldap_host}:389\" \n\
        connectionUsername=\"${ldap_user}\" \n\
        connectionPassword=${ldap_password} \n\
        authentication=simple \n\
        userBase=\"ou=User,ou=ActiveMQ,dc=activemq,dc=apache,dc=org\" \n\
        userRoleName=dummyUserRoleName \n\
        userSearchMatching=\"(uid={0})\" \n\
        userSearchSubtree=false \n\
        roleBase=\"ou=Group,ou=ActiveMQ,dc=activemq,dc=apache,dc=org\" \n\
        roleName=cn \n\
        roleSearchMatching=\"(member:=uid={1})\" \n\
        roleSearchSubtree=true \n\
        ;\n\
    };"
    #sed -i "s|##### LDAP_CONFIG #####|${ldapConfiguration}|" "$LOGIN_FILE"
    sed -i "s|\/\* ##### LDAP_CONFIG ##### \*\/|${ldapConfiguration}|" "$LOGIN_FILE"
    authentication="<jaasAuthenticationPlugin configuration=\"LdapConfiguration\" />"
#	    <!--
#            <authorizationPlugin>\n\
#              <map>\n\
#                <cachedLDAPAuthorizationMap\n\
#                    connectionURL=\"ldap://${ldap_host}:389\"\n\
#                    connectionUsername=\"${ldap_user}\"\n\
#                    connectionPassword=\"${ldap_password}\"\n\
#                    queueSearchBase=\"ou=Queue,ou=Destination,ou=ActiveMQ,dc=activemq,dc=apache,dc=org\"\n\
#                    topicSearchBase=\"ou=Topic,ou=Destination,ou=ActiveMQ,dc=activemq,dc=apache,dc=org\"\n\
#                    tempSearchBase=\"ou=Temp,ou=Destination,ou=ActiveMQ,dc=activemq,dc=apache,dc=org\"\n\
#                    refreshInterval=\"300000\"\n\
#                    legacyGroupMapping=\"false\"\n\
#                />\n\
#             </map>\n\
#            </authorizationPlugin>-->"
  else
    authentication="<jaasAuthenticationPlugin configuration=\"activemq-guest\" />"
  fi
  sed -i "s|<!-- ##### AUTHENTICATION ##### -->|${authentication}|" "$CONFIG_FILE"
}

function configureDestinations() {
  IFS=',' read -a queues <<< ${AMQ_QUEUES}
  IFS=',' read -a topics <<< ${AMQ_TOPICS}

  if [ "${#queues[@]}" -ne "0" -o "${#topics[@]}" -ne "0" ]; then
    destinations="<destinations>"
    if [ "${#queues[@]}" -ne "0" ]; then
      for queue in ${queues[@]}; do
        destinations="${destinations}<queue physicalName=\"${queue}\"/>"
      done
    fi
    if [ "${#topics[@]}" -ne "0" ]; then
      for topic in ${topics[@]}; do
        destinations="${destinations}<topic physicalName=\"${topic}\"/>"
      done
    fi
    destinations="${destinations}</destinations>"
    sed -i "s|<!-- ##### DESTINATIONS ##### -->|${destinations}|" "$CONFIG_FILE"
  fi
}

function sslPartial() {
  [ -n "$AMQ_KEYSTORE_TRUSTSTORE_DIR" -o -n "$AMQ_KEYSTORE" -o -n "$AMQ_TRUSTSTORE" -o -n "$AMQ_KEYSTORE_PASSWORD" -o -n "$AMQ_TRUSTSTORE_PASSWORD" ]
}

function sslEnabled() {
  [ -n "$AMQ_KEYSTORE_TRUSTSTORE_DIR" -a -n "$AMQ_KEYSTORE" -a -n "$AMQ_TRUSTSTORE" -a -n "$AMQ_KEYSTORE_PASSWORD" -a -n "$AMQ_TRUSTSTORE_PASSWORD" ]
}

function configureSSL() {
  sslDir=$(find_env "AMQ_KEYSTORE_TRUSTSTORE_DIR" "")
  keyStoreFile=$(find_env "AMQ_KEYSTORE" "")
  trustStoreFile=$(find_env "AMQ_TRUSTSTORE" "")
  
  if sslEnabled ; then
    keyStorePassword=$(find_env "AMQ_KEYSTORE_PASSWORD" "")
    trustStorePassword=$(find_env "AMQ_TRUSTSTORE_PASSWORD" "")

    keyStorePath="$sslDir/$keyStoreFile"
    trustStorePath="$sslDir/$trustStoreFile"

    sslElement="<sslContext>\n\
            <sslContext keyStore=\"file:$keyStorePath\"\n\
                        keyStorePassword=\"$keyStorePassword\"\n\
                        trustStore=\"file:$trustStorePath\"\n\
                        trustStorePassword=\"$trustStorePassword\" />\n\
        </sslContext>"

    sed -i "s|<!-- ##### SSL_CONTEXT ##### -->|${sslElement}|" "$CONFIG_FILE"
  elif sslPartial ; then
    echo "WARNING! Partial ssl configuration, the ssl context WILL NOT be configured."
  fi
}

function configureStoreUsage() {
  storeUsage=$(find_env "AMQ_STORAGE_USAGE_LIMIT" "100 gb")
  sed -i "s|##### STORE_USAGE #####|${storeUsage}|" "$CONFIG_FILE"
}

function configureTransportOptions() {
  IFS=',' read -a transports <<< $(find_env "AMQ_TRANSPORTS" "openwire,mqtt,amqp,stomp")
  maxConnections=$(find_env "AMQ_MAX_CONNECTIONS" "1000")
  maxFrameSize=$(find_env "AMQ_FRAME_SIZE" "104857600")

  if [ "${#transports[@]}" -ne "0" ]; then
    transportConnectors="<transportConnectors>"
    for transport in ${transports[@]}; do
      case "${transport}" in
        "openwire")
          transportConnectors="${transportConnectors}\n            <transportConnector name=\"openwire\" uri=\"tcp://0.0.0.0:61616?maximumConnections=${maxConnections}\&amp;wireFormat.maxFrameSize=${maxFrameSize}\" />"
          if sslEnabled ; then
            transportConnectors="${transportConnectors}\n            <transportConnector name=\"ssl\" uri=\"ssl://0.0.0.0:61617?maximumConnections=${maxConnections}\&amp;wireFormat.maxFrameSize=${maxFrameSize}\" />"
          fi
          ;;
        "mqtt")
          transportConnectors="${transportConnectors}\n            <transportConnector name=\"mqtt\" uri=\"mqtt://0.0.0.0:1883?maximumConnections=${maxConnections}\&amp;wireFormat.maxFrameSize=${maxFrameSize}\" />"
          if sslEnabled ; then
            transportConnectors="${transportConnectors}\n            <transportConnector name=\"mqtt+ssl\" uri=\"mqtt+ssl://0.0.0.0:8883?maximumConnections=${maxConnections}\&amp;wireFormat.maxFrameSize=${maxFrameSize}\" />"
          fi
          ;;
        "amqp")
          transportConnectors="${transportConnectors}\n            <transportConnector name=\"amqp\" uri=\"amqp://0.0.0.0:5672?maximumConnections=${maxConnections}\&amp;wireFormat.maxFrameSize=${maxFrameSize}\" />"
          if sslEnabled ; then
            transportConnectors="${transportConnectors}\n            <transportConnector name=\"amqp+ssl\" uri=\"amqp+ssl://0.0.0.0:5671?maximumConnections=${maxConnections}\&amp;wireFormat.maxFrameSize=${maxFrameSize}\" />"
          fi
          ;;
        "stomp")
          transportConnectors="${transportConnectors}\n            <transportConnector name=\"stomp\" uri=\"stomp://0.0.0.0:61613?maximumConnections=${maxConnections}\&amp;wireFormat.maxFrameSize=${maxFrameSize}\" />"
          if sslEnabled ; then
            transportConnectors="${transportConnectors}\n            <transportConnector name=\"stomp+ssl\" uri=\"stomp+ssl://0.0.0.0:61612?maximumConnections=${maxConnections}\&amp;wireFormat.maxFrameSize=${maxFrameSize}\" />"
          fi
          ;;
      esac
    done
    transportConnectors="${transportConnectors}\n        </transportConnectors>"
    sed -i "s|<!-- ##### TRANSPORT_CONNECTORS ##### -->|${transportConnectors}|" "$CONFIG_FILE"
  fi
}

cp "${OPENSHIFT_CONFIG_FILE}" "${CONFIG_FILE}"
cp "${OPENSHIFT_LOGIN_FILE}" "${LOGIN_FILE}"
cp "${OPENSHIFT_USERS_FILE}" "${USERS_FILE}"

configureAuthentication
configureDestinations
configureSSL
configureStoreUsage
configureTransportOptions
checkViewEndpointsPermission
configureMesh
