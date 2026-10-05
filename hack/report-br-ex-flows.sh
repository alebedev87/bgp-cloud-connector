#!/usr/bin/env bash
#
# Record the br-ex OpenFlow flows on every worker, and say per worker
# which of the flows OVN-Kubernetes adds for an advertised network are
# there.
#
#   hack/report-br-ex-flows.sh <bgprouting.yaml> [<dir>]
#
# The full `ovs-ofctl dump-flows br-ex` of each worker goes to
# <dir>/<node>.txt. Defaults to a fresh temporary directory. Pass one to
# keep it.
#
# For each subnet in the BGPRouting, four flows carry the advertised
# network through br-ex:
#
#   ingress   table=0 priority=300  nw_dst=<subnet> -> output to the network
#   egress    table=0 priority=104  nw_src=<subnet> -> output to the uplink
#   services  table=0 priority=550  from LOCAL, nw_src=<subnet> to a service
#   t2-drop   table=2 priority=200  nw_src=<subnet> -> drop
#
# A node can advertise the subnet over BGP and still be missing these,
# and then it does not answer traffic for pods on that network. The
# patterns match the IPv4 forms only.
#
# Nothing in the cluster is changed. A worker whose flows cannot be read
# is reported and the rest are still read; the exit status is non-zero
# if any were not.

set -o nounset
set -o errexit
set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=hack/lib/common.sh
source "${repo_root}/hack/lib/common.sh"

router_label_key="${ROUTER_LABEL_KEY:-bgp_router}"
router_label_value="${ROUTER_LABEL_VALUE:-true}"

(( $# >= 1 && $# <= 2 )) \
    || die "Usage: ${0##*/} <bgprouting.yaml> [<dir>]"
manifest="$1"
out_dir="${2:-}"

require_cmd oc
require_cluster

# From the manifest rather than the cluster, because the e2e suites'
# cleanup specs delete the BGPRouting and this runs after them. A
# client-side dry run parses the file without creating anything; it
# still needs the cluster to know the kind.
fields="$(oc create --dry-run=client -f "${manifest}" \
    -o jsonpath='{.spec.network.subnets[*]}' 2>&1)" \
    || die "cannot read the subnets from ${manifest}" "${fields}"
mapfile -t subnets < <(print_fields "${fields}")
(( ${#subnets[@]} > 0 )) || die "${manifest} names no subnets"

if [[ -z "${out_dir}" ]]; then
    out_dir="$(mktemp -d)"
fi
mkdir -p "${out_dir}"

# '|' rather than a tab: read collapses runs of whitespace separators,
# so a node without the router label would shift its fields left.
workers="$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath="{range .items[*]}{.metadata.name}|{.metadata.labels.topology\.kubernetes\.io/zone}|{.metadata.labels.${router_label_key//./\\.}}{\"\n\"}{end}" 2>&1)" \
    || die "cannot list worker nodes" "${workers}"
[[ -n "${workers}" ]] || die "no nodes with the worker role"

# Prints the summary fields for one subnet in one dump.
flow_summary() {
    local dump="$1" subnet="$2" re
    re="${subnet//./\\.}"
    local -A patterns=(
        [ingress]="table=0, .*priority=300,ip,in_port=[^,]+,nw_dst=${re} actions=output:"
        [egress]="table=0, .*priority=104,ip,in_port=[^,]+,dl_src=[^,]+,nw_src=${re} actions=output:"
        [services]="table=0, .*priority=550,ip,in_port=LOCAL,nw_src=${re},nw_dst=[^ ]+ actions=ct\(commit,table=2,"
        [t2-drop]="table=2, .*priority=200,ip,nw_src=${re} actions=drop"
    )
    local line="${subnet}" flow
    for flow in ingress egress services t2-drop; do
        if grep -Eq "${patterns[${flow}]}" "${dump}"; then
            line+=" ${flow}=yes"
        else
            line+=" ${flow}=NO"
        fi
    done
    printf '%s' "${line}"
}

while IFS='|' read -r node zone label; do
    router=false
    [[ "${label}" == "${router_label_value}" ]] && router=true
    prefix="${node} zone=${zone:-none} router=${router}"

    pod="$(oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node \
        --field-selector "spec.nodeName=${node}" -o name 2>&1)" || true
    if [[ "${pod}" != pod/* ]]; then
        info "${prefix} flows unreadable"
        fail "no ovnkube-node pod found on ${node}${pod:+: ${pod}}"
        continue
    fi

    dump="${out_dir}/${node}.txt"
    if ! err="$(oc -n openshift-ovn-kubernetes exec "${pod}" -c ovn-controller \
        -- ovs-ofctl dump-flows br-ex 2>&1 >"${dump}")"; then
        info "${prefix} flows unreadable"
        fail "cannot dump br-ex on ${node} via ${pod}: ${err}"
        continue
    fi

    line="${prefix}"
    for subnet in "${subnets[@]}"; do
        line+=" $(flow_summary "${dump}" "${subnet}")"
    done
    info "${line}"
done <<<"${workers}"

info "br-ex flows written to ${out_dir}"
report
