#!/usr/bin/env bash
# Deploys a kubernetes bundle, and an e2e charm and runs the e2e tests.

set -o errexit  # Exit when an individual command fails.
set -o nounset  # Exit when undeclaried variables are used.
set -o pipefail  # The exit status of the last command is returned.
set -o xtrace  # Print the commands that are executed.


# A full path to the location of the JUJU_DATA.
JUJU_DATA=${JUJU_DATA:-"${HOME}/.local/share/juju"}

# Juju is not installed define the juju functions that use containers.
source define-juju.sh

# Create a model namme for this build.
MODEL="${BUILD_TAG}"
# Create a model just for this run of the tests.
in-jujubox "sudo chown -R ubuntu:ubuntu /home/ubuntu/.local/share/juju && juju add-model ${MODEL}"
# Catch all EXITs from this script and make sure to destroy the model.
trap "juju destroy-model -y ${MODEL}" EXIT

# Set test mode on the deployment so we dont bloat charm-store deployment count
juju model-config -m ${MODEL} test-mode=1

# Deploy the kubernetes bundle.
juju deploy cs:~containers/kubernetes-core
# Deploy the e2e charm.
juju deploy cs:~containers/kubernetes-e2e
juju add-unit kubernetes-worker
juju relate kubernetes-e2e kubernetes-master
juju relate kubernetes-e2e easyrsa

sleep 10
# Wait for the deployment to be ready TODO make this a function with max wait.
set +x
until juju status -m ${MODEL} | grep "Ready to test."; do
  sleep 10
done
until [ "$(juju status -m ${MODEL} | grep "Kubernetes worker running." | wc -l)" -eq "2" ]; do
  sleep 10
done
set -x

# Run the e2e test action.
ACTION_ID=$(juju run-action kubernetes-e2e/0 test | cut -d " " -f 5)
# Wait for the action to be complete.
while juju show-action-status ${ACTION_ID} | grep pending || juju show-action-status ${ACTION_ID} | grep running; do
  sleep 5
done
juju show-action-status ${ACTION_ID}

# Download results and move them to the bind mount
in-jujubox "juju scp kubernetes-e2e/0:${ACTION_ID}.log.tar.gz /tmp/e2e.log.tar.gz; sudo mv /tmp/e2e.log.tar.gz /home/ubuntu/workspace"
in-jujubox "juju scp kubernetes-e2e/0:${ACTION_ID}-junit.tar.gz /tmp/e2e-junit.tar.gz; sudo mv /tmp/e2e-junit.tar.gz /home/ubuntu/workspace"

export ARTIFACTS=${WORKSPACE}/artifacts
# Create the artifacts directory.
mkdir -p ${ARTIFACTS}
# Extract the results into the artifacts directory.
tar xvfz ${WORKSPACE}/e2e-junit.tar.gz -C ${ARTIFACTS}
tar xvfz ${WORKSPACE}/e2e.log.tar.gz -C ${ARTIFACTS}
# Rename the ACTION_ID log file to build-log.txt
mv ${ARTIFACTS}/${ACTION_ID}.log ${ARTIFACTS}/build-log.txt

# Call the gubernator script to copy the results to the right format.
./gubernator.sh
