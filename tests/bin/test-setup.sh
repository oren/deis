#!/bin/bash
#
# Prepares the process environment to run a test

function log_phase {
    echo
    echo ">>> $1 <<<"
    echo
}

log_phase "Preparing test environment"

# use GOPATH to determine project root
export DEIS_ROOT=${GOPATH?}/src/github.com/deis/deis
echo "DEIS_ROOT=$DEIS_ROOT"

# prepend GOPATH/bin to PATH
export PATH=${GOPATH}/bin:$PATH

# the application under test
export DEIS_TEST_APP=${DEIS_TEST_APP:-example-dockerfile-http}
echo "DEIS_TEST_APP=$DEIS_TEST_APP"

# SSH key name used for testing
export DEIS_TEST_AUTH_KEY=${DEIS_TEST_AUTH_KEY:-deis-test}
echo "DEIS_TEST_AUTH_KEY=$DEIS_TEST_AUTH_KEY"

# SSH key used for deisctl tunneling
export DEIS_TEST_SSH_KEY=${DEIS_TEST_SSH_KEY:-~/.vagrant.d/insecure_private_key}
echo "DEIS_TEST_SSH_KEY=$DEIS_TEST_SSH_KEY"

# domain used for wildcard DNS
export DEIS_TEST_DOMAIN=${DEIS_TEST_DOMAIN:-local3.deisapp.com}
echo "DEIS_TEST_DOMAIN=$DEIS_TEST_DOMAIN"

# SSH tunnel used by deisctl
export DEISCTL_TUNNEL=${DEISCTL_TUNNEL:-127.0.0.1:2222}
echo "DEISCTL_TUNNEL=$DEISCTL_TUNNEL"

# set units used by deisctl
export DEISCTL_UNITS=${DEISCTL_UNITS:-$DEIS_ROOT/deisctl/units}
echo "DEISCTL_UNITS=$DEISCTL_UNITS"

# ip address for docker containers to communicate in functional tests
export HOST_IPADDR=${HOST_IPADDR?}
echo "HOST_IPADDR=$HOST_IPADDR"

# the registry used to host dev-release images
# must be accessible to local Docker engine and Deis cluster
export DEV_REGISTRY=${DEV_REGISTRY?}
echo "DEV_REGISTRY=$DEV_REGISTRY"

# bail if registry is not accessible
if ! curl -s $DEV_REGISTRY; then
  echo "DEV_REGISTRY is not accessible, exiting..."
  exit 1
fi
echo ; echo

# disable git+ssh host key checking
export GIT_SSH=$DEIS_ROOT/tests/bin/git-ssh-nokeycheck.sh

# install required go dependencies
go get -v github.com/golang/lint/golint
go get -v github.com/tools/godep

# cleanup any stale example applications
rm -rf $DEIS_ROOT/tests/example-*

# generate ssh keys if they don't already exist
test -e ~/.ssh/$DEIS_TEST_AUTH_KEY || ssh-keygen -t rsa -f ~/.ssh/$DEIS_TEST_AUTH_KEY -N ''
# TODO: parameterize this key required for keys_test.go?
test -e ~/.ssh/deiskey || ssh-keygen -q -t rsa -f ~/.ssh/deiskey -N '' -C deiskey

# prepare the SSH agent
ssh-add -D || eval $(ssh-agent) && ssh-add -D
ssh-add ~/.ssh/$DEIS_TEST_AUTH_KEY
ssh-add $DEIS_TEST_SSH_KEY

# clean out deis session data
rm -rf ~/.deis

# wipe out all vagrants & deis virtualboxen
function cleanup {
    log_phase "Cleaning up"
    set +e
    ${GOPATH}/src/github.com/deis/deis/tests/bin/destroy-all-vagrants.sh
    VBoxManage list vms | grep deis | sed -n -e 's/^.* {\(.*\)}/\1/p' | xargs -L1 -I {} VBoxManage unregistervm {} --delete
    vagrant global-status --prune
    docker rm -f -v `docker ps | grep deis- | awk '{print $1}'` 2>/dev/null
    log_phase "Test run complete"
}

function dump_logs {
  log_phase "Error detected, dumping logs"
  TIMESTAMP=`date +%Y-%m-%d-%H%M%S`
  FAILED_LOGS_DIR=$HOME/deis-test-failure-$TIMESTAMP
  mkdir -p $FAILED_LOGS_DIR
  set +e
  export FLEETCTL_TUNNEL=$DEISCTL_TUNNEL
  fleetctl -strict-host-key-checking=false list-units
  # application unit logs
  get_logs appssample_v2.web.1
  get_logs appssample_v2.run.1
  get_logs buildsample_v2.web.1
  get_logs buildsample_v3.cmd.1
  get_logs deispullsample_v2.cmd.1
  get_logs deispullsample_v2.worker.1
  get_logs pssample_v2.worker.1
  get_logs pssample_v2.worker.2
  # etcd keyspace
  get_logs deis-controller "etcdctl ls / --recursive" etcdctl-dump
  # component logs
  get_logs deis-builder
  get_logs deis-controller
  get_logs deis-database
  get_logs deis-logger
  get_logs deis-registry
  get_logs deis-router@1 deis-router deis-router-1
  get_logs deis-router@2 deis-router deis-router-2
  get_logs deis-router@3 deis-router deis-router-3
  # deis-store logs
  get_logs deis-router@1 deis-store-monitor deis-store-monitor-1
  get_logs deis-router@1 deis-store-daemon deis-store-daemon-1
  get_logs deis-router@1 deis-store-metadata deis-store-metadata-1
  get_logs deis-router@1 deis-store-volume deis-store-volume-1
  get_logs deis-router@2 deis-store-monitor deis-store-monitor-2
  get_logs deis-router@2 deis-store-daemon deis-store-daemon-2
  get_logs deis-router@2 deis-store-metadata deis-store-metadata-2
  get_logs deis-router@2 deis-store-volume deis-store-volume-2
  get_logs deis-router@3 deis-store-monitor deis-store-monitor-3
  get_logs deis-router@3 deis-store-daemon deis-store-daemon-3
  get_logs deis-router@3 deis-store-metadata deis-store-metadata-3
  get_logs deis-router@3 deis-store-volume deis-store-volume-3
  get_logs deis-store-gateway

  # tarball logs
  BUCKET=jenkins-failure-logs
  FILENAME=deis-test-failure-$TIMESTAMP.tar.gz
  cd $FAILED_LOGS_DIR && tar -czf $FILENAME *.log && mv $FILENAME .. && cd ..
  rm -rf $FAILED_LOGS_DIR
  if [ `which s3cmd` ] && [ -f $HOME/.s3cfg ]; then
    echo "configured s3cmd found in path. Attempting to upload logs to S3"
    s3cmd put $HOME/$FILENAME s3://$BUCKET
    rm $HOME/$FILENAME
    echo "Logs are accessible at https://s3.amazonaws.com/$BUCKET/$FILENAME"
  else
    echo "Logs are accessible at $HOME/$FILENAME"
  fi
  exit 1
}

function get_logs {
  TARGET="$1"
  CONTAINER="$2"
  FILENAME="$3"
  if [ -z "$CONTAINER" ]; then
    CONTAINER=$TARGET
  fi
  if [ -z "$FILENAME" ]; then
    FILENAME=$TARGET
  fi
  fleetctl -strict-host-key-checking=false ssh "$TARGET" docker logs "$CONTAINER" > $FAILED_LOGS_DIR/$FILENAME.log
}
