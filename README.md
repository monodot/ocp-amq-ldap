# ocp-amq-ldap

Demonstrating how to use S2I to configure LDAP authentication in ActiveMQ, using [JBoss A-MQ for OpenShift][1].

- Overrides the `configure.sh` script supplied with the A-MQ image to add LDAP configuration

## To build and run locally

Using the [OpenShift source-to-image][s2i] tool:

    $ git clone https://github.com/ocp-amq-ldap
    $ cd ocp-amq-ldap
    $ s2i build . registry.access.redhat.com/jboss-amq-6/amq62-openshift ocp-amq-ldap
    
**To run**

First start a demo LDAP server:

    $ docker run -p 389:389 -v /tmp/slapd/data/ldap:/var/lib/ldap \
           -e LDAP_DOMAIN=activemq.apache.org \
           -e LDAP_ORGANISATION="Apache ActiveMQ Test Org" \
           -e LDAP_ROOTPASS=sunflower \
           -e CONSOLE_LOG_LEVEL=7 \
           --name ocp-amq-slapd \
           -d nickstenning/slapd

Add some test data (provided in `/data`):

    $ ldapadd -h localhost -p 389 -c -x -D cn=admin,dc=activemq,dc=apache,dc=org -w sunflower -f data/activemq-openldap.ldif

Now start a new container from the LDAP-configured A-MQ image, pointing to the _slapd_ LDAP server:

    $ SLAPD_IP=`docker inspect -f '{{ .NetworkSettings.IPAddress }}' ocp-amq-slapd`
    $ docker run -d -e LDAP_HOST=$SLAPD_IP -e LDAP_USER=cn=mqbroker,ou=Services,dc=activemq,dc=apache,dc=org -e LDAP_PASSWORD=sunflower --name ocp-amq-ldap ocp-amq-ldap

To send a test message, start a bash shell in the container and run:

    $ docker exec -it ocp-amq-ldap /opt/amq/bin/activemq producer --messageCount 1 --user jdoe --password sunflower

## To customise

To make broker-to-broker communication happen only over SSL, set the following environment variables on the container:

- `AMQ_MESH_SERVICE_PORT` should be `61617`
- `AMQ_MESH_SERVICE_TRANSPORT` should be `ssl`

If running inside OpenShift, set these environment variables on your DeploymentConfig using `oc set env dc/yourname ENV=var`.

[1]: https://access.redhat.com/documentation/en/red-hat-jboss-middleware-for-openshift/3/paged/red-hat-jboss-a-mq-for-openshift/
[s2i]: https://github.com/openshift/source-to-image



