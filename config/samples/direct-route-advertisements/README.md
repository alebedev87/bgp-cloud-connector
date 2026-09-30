# Advertise a user-managed CUDN without BGPRouting

This example uses the existing operator without creating a `BGPRouting`.
You manage the namespace, `ClusterUserDefinedNetwork` (CUDN), and
`RouteAdvertisements` directly. `BGPCloudConfiguration` configures the BGP
infrastructure and generates the base `FRRConfiguration` objects. OVN-Kubernetes
uses those configurations and the selected CUDNs to generate the advertisement
configuration consumed by FRR-K8s.

## Prerequisites

- An OpenShift 4.21+ cluster with OVN-Kubernetes, the required route-advertisement
  feature enabled, and this operator installed; see [deployment](../../../docs/deployment.md).
- A BGP peer configured to accept sessions from the selected nodes, with matching
  ASNs and network connectivity. `platform: Manual` does not configure the peer,
  cloud forwarding settings, or cloud resources.
- An unused namespace name and a CUDN subnet that does not overlap your existing
  networks. Replace the example peer address, ASNs, and subnet before applying.

The label keys under `networking.example.com` are example user-defined labels.
They do not require changes to the operator.

## Apply

Run these commands from the repository root. Label each intended router node:

```bash
oc label node <router-node-name> bgp_router=true
```

Edit and apply the infrastructure configuration, then wait for reconciliation:

```bash
$EDITOR config/samples/direct-route-advertisements/01-bgpcloudconfiguration.yaml
oc apply -f config/samples/direct-route-advertisements/01-bgpcloudconfiguration.yaml
oc wait bgpcloudconfiguration/cluster --for=jsonpath='{.status.phase}'=Ready --timeout=300s
oc wait crd/routeadvertisements.k8s.ovn.org --for=condition=Established --timeout=300s
```

`BGPCloudConfiguration` is a singleton named `cluster`. If you already have one,
reuse it and skip applying `01-bgpcloudconfiguration.yaml`; this example must not
overwrite an existing cloud configuration. AWS, Azure, and GCP configurations
work with the same network and advertisement manifests.

Create the namespace and network, then the advertisement policy:

```bash
$EDITOR config/samples/direct-route-advertisements/02-network.yaml
oc apply -f config/samples/direct-route-advertisements/02-network.yaml
oc apply -f config/samples/direct-route-advertisements/03-routeadvertisements.yaml
```

Create application workloads in `blue-apps` after the CUDN reports ready. The
namespace's primary-network label is supplied at creation time.

## Verify

```bash
oc get bgpcloudconfiguration cluster
oc get clusteruserdefinednetwork blue -o yaml
oc get routeadvertisements external-bgp-networks -o yaml
oc get frrconfigurations -n openshift-frr-k8s
```

Check the CUDN's readiness conditions and the advertisement object's acceptance
conditions. The FRR configurations include the operator's base configurations
and OVN-generated advertisement configurations. Infrastructure `Ready` and
advertisement acceptance do not prove end-to-end connectivity: also confirm BGP
sessions and learned routes on the external peer and test access to a workload.

The advertisement selects CUDNs with
`networking.example.com/export-to: external-bgp` and base FRR configurations with
`app.kubernetes.io/managed-by: bgp-cloud-connector`. Add the CUDN label to further
networks to include them in the same policy. Do not put the operator's managed-by
label on your CUDN or advertisement object.

Leave `spec.targetVRF` unset: the operator's base FRR configurations use the
default VRF, represented by an empty VRF value. Setting `targetVRF: default`
explicitly caused a VRF mismatch and advertisement rejection on OpenShift 4.22.14.

The dedicated advertisement name and CUDN label avoid the generated
`bgp-cc-route-advertisements` object and its `advertise: "true"` selector when
other networks use `BGPRouting`.

See the [OpenShift RouteAdvertisements documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/advanced_networking/route-advertisements)
for selector and advertisement behavior.

### Live validation

Validated on OpenShift 4.22.14 with two worker nodes and a temporary in-cluster
FRR peer. The manual configuration used the peer's pod IP and `ebgpMultiHop: true`.
Both sessions established and the peer learned `10.100.0.0/16` from both workers,
without any `BGPRouting` objects. Deleting the advertisement withdrew the prefix
and removed the OVN-generated FRR configurations while preserving the original
CUDN, running workload, and base FRR configuration. Reapplying it restored both
advertised paths.

This validates BGP advertisement and withdrawal, not AWS routing or end-to-end
workload connectivity. An HTTP probe from the in-cluster peer to the workload
timed out.

### AWS Route Server validation

The same manifests were validated against an AWS VPC Route Server with
`platform: Manual`. The test used local ASN `65001` and Route Server ASN
`65000`; use the ASN configured on your Route Server, rather than assuming
either value. Three AWS peers reached `BgpStatus: up`, the CUDN prefix appeared
as an active `Advertisement` in the VPC route tables, and an EC2 client reached
a workload at `10.100.0.6:8080` with HTTP 200.

The AWS test also required TCP/179 from the Route Server endpoint subnets to the
router-node security group and TCP/8080 from the client subnet to the workers.
The latter is workload-specific: allow the service ports your external clients
need, and remove broad temporary test rules after validation. A BGP session and
an active route alone do not prove application connectivity.

## Stop advertising while preserving the network

Delete only the advertisement policy:

```bash
oc delete -f config/samples/direct-route-advertisements/03-routeadvertisements.yaml
```

This removes its advertisement contribution while preserving the CUDN,
namespace, workloads, and base peering. Other advertisement objects can still
advertise the same network if they select it.

Keep `BGPCloudConfiguration` while these peers are needed. Its current deletion
logic checks for `BGPRouting` instances before tearing down cloud peers and base
FRR configurations; it does not protect this direct advertisement dependency.
For full infrastructure teardown, remove dependent advertisement policies first
and allow OVN-Kubernetes to clean up its generated configurations. Delete the
network and namespace separately only when their workloads are no longer needed.
