# Advertise a user-managed CUDN without BGPRouting

This example uses the existing operator without creating a `BGPRouting`.
You manage the namespace, `ClusterUserDefinedNetwork` (CUDN), and
`RouteAdvertisements` directly. `BGPCloudConfiguration` configures the BGP
infrastructure and generates the base `FRRConfiguration` objects. OVN-Kubernetes
uses those configurations and the selected CUDNs to generate the advertisement
configuration consumed by FRR-K8s.

The direct CUDN advertisement path works with every supported platform
(`Manual`, `AWS`, `Azure`, and `GCP`). This sample provides ready-to-apply
infrastructure manifests for `Manual` and `AWS`; Azure and GCP use their usual
platform-specific `BGPCloudConfiguration` with the same network and
`RouteAdvertisements` manifests below.

## Prerequisites

- An OpenShift 4.21+ cluster with OVN-Kubernetes, the required route-advertisement
  feature enabled, and this operator installed; see [deployment](../../../docs/deployment.md).
- A BGP peer or cloud Route Server configured to accept sessions from the selected
  nodes, with matching ASNs and network connectivity.
- An unused namespace name and a CUDN subnet that does not overlap your existing
  networks. Replace the example values in the selected infrastructure manifest
  and the subnet before applying.

The label keys under `networking.example.com` are example user-defined labels.
They do not require changes to the operator.

## Apply

Run these commands from the repository root. First choose exactly one
infrastructure configuration:

- [`01-bgpcloudconfiguration-manual.yaml`](01-bgpcloudconfiguration-manual.yaml)
  configures explicit BGP neighbors without provisioning cloud networking.
- [`01-bgpcloudconfiguration-aws.yaml`](01-bgpcloudconfiguration-aws.yaml)
  discovers and manages AWS VPC Route Server peers. The Route Server must
  already exist, and AWS credentials/IAM permissions are required.

Do not apply both files; `BGPCloudConfiguration` is a singleton named `cluster`.
Then label each intended router node:

```bash
oc label node <router-node-name> bgp_router=true
```

For Manual:

```bash
$EDITOR config/samples/direct-route-advertisements/01-bgpcloudconfiguration-manual.yaml
oc apply -f config/samples/direct-route-advertisements/01-bgpcloudconfiguration-manual.yaml
```

For AWS:

```bash
$EDITOR config/samples/direct-route-advertisements/01-bgpcloudconfiguration-aws.yaml
oc apply -f config/samples/direct-route-advertisements/01-bgpcloudconfiguration-aws.yaml
```

Then wait for reconciliation:

```bash
oc wait bgpcloudconfiguration/cluster --for=jsonpath='{.status.phase}'=Ready --timeout=300s
oc wait crd/routeadvertisements.k8s.ovn.org --for=condition=Established --timeout=300s
```

If you already have a `BGPCloudConfiguration`, reuse it and skip applying either
infrastructure file; this example must not overwrite an existing cloud
configuration. The same network and advertisement manifests work with AWS,
Azure, and GCP configurations.

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

The same network and advertisement manifests can be used with an AWS
`BGPCloudConfiguration` using `platform: AWS`; only the infrastructure
configuration changes. In that mode the operator discovers the Route Server
peers and reconciles them for the selected nodes. The test version used local
ASN `65001` and Route Server ASN `65000`; use the ASN configured on your Route
Server, rather than assuming either value. Three AWS peers reached
`BgpStatus: up`, the CUDN prefix appeared as an active `Advertisement` in the
VPC route tables, and an EC2 client reached a workload at `10.100.0.6:8080`
with HTTP 200.

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
