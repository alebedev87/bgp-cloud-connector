# shellcheck shell=bash
#
# The AWS half of the prow bootstrap. Source this, do not run it: it is
# what the hack/ci-e2e-aws*.sh entry points source instead of
# hack/lib/ci.sh, and it defines ci_bootstrap in terms of the
# cloud-neutral pieces there.
#
# Everything that knows the credentials are AWS's is in this file, so
# that adding a cloud adds a file beside it rather than a branch inside
# lib/ci.sh.

# shellcheck source=hack/lib/ci.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/ci.sh"
# shellcheck source=hack/aws/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# In prow the cluster profile supplies the credentials. Outside it,
# whatever is already in the environment is used -- an AWS_PROFILE, or a
# credentials file somebody exported.
#
# A cluster profile with no .awscred in it is a failure rather than a
# reason to fall back, for the same reason an empty SHARED_DIR is: the
# fallback would reach for a developer's own credentials, and in a job
# there are none.
ci_aws_shared_credentials() {
    [[ -n "${CLUSTER_PROFILE_DIR:-}" ]] || return 0
    [[ -f "${CLUSTER_PROFILE_DIR}/.awscred" ]] \
        || die "CLUSTER_PROFILE_DIR is set but has no .awscred" \
               "Looked in ${CLUSTER_PROFILE_DIR}"
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
}

ci_bootstrap() {
    ci_aws_shared_credentials
    ci_use_shared_kubeconfig
    ci_make_workdir
}
