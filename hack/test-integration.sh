#!/bin/bash

# Copyright 2014 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# any command line arguments will be passed to hack/build_go.sh to build the
# cmd/integration binary.  --use_go_build is a legitimate argument, as are
# any other build time arguments.

set -o errexit
set -o nounset
set -o pipefail

KUBE_ROOT=$(dirname "${BASH_SOURCE}")/..
source "${KUBE_ROOT}/hack/lib/init.sh"
# Lists of API Versions of each groups that should be tested, groups are
# separated by comma, lists are separated by semicolon. e.g.,
# "v1,compute/v1alpha1,experimental/v1alpha2;v1,compute/v2,experimental/v1alpha3"
# TODO: It's going to be:
# KUBE_TEST_API_VERSIONS=${KUBE_TEST_API_VERSIONS:-"v1,extensions/v1beta1"}
KUBE_TEST_API_VERSIONS=${KUBE_TEST_API_VERSIONS:-"v1,extensions/v1beta1;v1,autoscaling/v1,batch/v1,apps/v1alpha1,policy/v1alpha1,extensions/v1beta1,rbac.authorization.k8s.io/v1alpha1"}

# Give integration tests longer to run
# TODO: allow a larger value to be passed in
#KUBE_TIMEOUT=${KUBE_TIMEOUT:--timeout 240s}
KUBE_TIMEOUT="-timeout 600s"
KUBE_INTEGRATION_TEST_MAX_CONCURRENCY=${KUBE_INTEGRATION_TEST_MAX_CONCURRENCY:-"-1"}
LOG_LEVEL=${LOG_LEVEL:-2}
KUBE_TEST_ARGS=${KUBE_TEST_ARGS:-}

cleanup() {
  kube::log::status "Cleaning up etcd"
  kube::etcd::cleanup
  kube::log::status "Integration test cleanup complete"
}

runTests() {
  kube::log::status "Starting etcd instance"
  kube::etcd::start
  kube::log::status "Running integration test cases"

  # TODO: Re-enable race detection when we switch to a thread-safe etcd client
  # KUBE_RACE="-race"
  KUBE_GOFLAGS="${KUBE_GOFLAGS:-} -tags 'integration no-docker'" \
    KUBE_RACE="" \
    KUBE_TIMEOUT="${KUBE_TIMEOUT}" \
    KUBE_TEST_API_VERSIONS="$1" \
    "${KUBE_ROOT}/hack/test-go.sh" test/integration

  # Run the watch cache tests
  # KUBE_TEST_ARGS doesn't mean anything to the watch cache test.
  if [[ -z "${KUBE_TEST_ARGS}" ]]; then
    kube::log::status "Running integration test scenario with watch cache on"
    KUBE_TEST_API_VERSIONS="$1" "${KUBE_OUTPUT_HOSTBIN}/integration" --v=${LOG_LEVEL} \
      --max-concurrency="${KUBE_INTEGRATION_TEST_MAX_CONCURRENCY}" --watch-cache=true
  fi

  cleanup
}

checkEtcdOnPath() {
  kube::log::status "Checking etcd is on PATH"
  which etcd && return
  kube::log::status "Cannot find etcd, cannot run integration tests."
  kube::log::status "Please see docs/devel/testing.md for instructions."
  return 1
}

checkEtcdOnPath

"${KUBE_ROOT}/hack/build-go.sh" "$@" cmd/integration

# Run cleanup to stop etcd on interrupt or other kill signal.
trap cleanup EXIT

# If a test case is specified, just run once with v1 API version and exit
if [[ -n "${KUBE_TEST_ARGS}" ]]; then
  runTests v1
fi

# Convert the CSV to an array of API versions to test
IFS=';' read -a apiVersions <<< "${KUBE_TEST_API_VERSIONS}"
for apiVersion in "${apiVersions[@]}"; do
  runTests "${apiVersion}"
done
