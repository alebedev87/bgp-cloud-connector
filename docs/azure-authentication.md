# Azure authentication

The operator needs Azure credentials to manage the Route Server's BGP connections and to enable IP forwarding on the router nodes' network interfaces (see [cloud-integration.md](cloud-integration.md)). It gets them the same way it does on [AWS](aws-authentication.md): it creates a `CredentialsRequest` for itself and reads the secret the **Cloud Credential Operator (CCO)** writes in reply. What you have to set up depends on how your cluster hands out Azure credentials.

## Which setup applies

| Your cluster | What you do | Details |
|:---|:---|:---|
| **Azure IPI, passthrough** (the default) | Nothing | [Passthrough](#passthrough) |
| **ARO classic with a service principal** | Grant the cluster's principal a role on the resource group holding the Route Server | [ARO with a service principal](#aro-with-a-service-principal) |
| **Azure IPI, Manual mode with workload identity** (`ccoctl`) | Create a managed identity for the operator and give its ids to the Subscription | [Workload identity](#workload-identity) |
| **ARO classic with managed identities** | As workload identity, plus a second identity for the network interfaces | [ARO with managed identities](#aro-with-managed-identities) |

## How the operator gets a credential

During reconciliation `ResolveCredentials` (`internal/platform/azure/credentials.go`) reads the secret `bgp-cloud-connector-azure-credentials` in the operator's namespace. CCO writes it in reply to the operator's `CredentialsRequest`, `bgp-cloud-connector-azure` in `openshift-cloud-credential-operator`, which asks for these permissions:

```
Microsoft.Network/virtualHubs/read
Microsoft.Network/virtualHubs/bgpConnections/read
Microsoft.Network/virtualHubs/bgpConnections/write
Microsoft.Network/virtualHubs/bgpConnections/delete
Microsoft.Network/networkInterfaces/read
Microsoft.Network/networkInterfaces/write
```

They are not everything an interface write needs. Azure also checks the `join` actions on the subnet and load balancer backend pool the interface belongs to; see step 2 of [Workload identity](#workload-identity).

What the secret holds tells the operator which kind of credential it is. With `azure_client_secret` it authenticates as a service principal; with `azure_federated_token_file` and no client secret it exchanges its projected ServiceAccount token, at `/var/run/secrets/openshift/serviceaccount/token` with audience `openshift`, for a token for the managed identity the secret names. Either way it asks for a token before using the credential, so a credential Azure refuses is reported as a credentials problem rather than a discovery one.

The secret is read on every reconcile, so a rotated credential takes effect without a restart. The `CredentialsRequest` is reconciled on every pass too, so it keeps up with the permissions the running release asks for.

Where there is no secret, the operator falls back to the Azure SDK's default credential chain. That is what serves a manager run from your desk against an `az login`; in a pod the chain finds nothing, because the image carries no `az` and the instance metadata service is unreachable from the pod network.

## Passthrough

`credentialsMode` unset or `Passthrough`, which is how Azure IPI installs by default. **Nothing to set up.** CCO copies the cluster's own credential into the operator's secret. The `BGPCloudConfiguration` reports `CloudEndpointsDiscovered=False` with reason `WaitingForCloudCredentials` for the few seconds this takes, then proceeds.

In passthrough the `permissions` list does not limit anything: the operator holds whatever the cluster's principal holds.

## ARO with a service principal

ARO classic built with a service principal is passthrough too, so the operator receives the cluster principal's credential. ARO gives that principal `Contributor` on the managed resource group and `Network Contributor` on the virtual network, so it can write the router nodes' network interfaces. The Route Server is a separate resource in the resource group holding the virtual network, which neither role covers, so the operator is refused when it tries to find or peer it.

Grant it one. The principal is the one CCO passes through, named in `kube-system/azure-credentials`:

```bash
client_id=$(oc -n kube-system get secret azure-credentials -o jsonpath='{.data.azure_client_id}' | base64 -d)
object_id=$(az ad sp show --id "$client_id" --query id -o tsv)
net_rg=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.azure.networkResourceGroupName}')
az role assignment create --assignee-object-id "$object_id" --assignee-principal-type ServicePrincipal \
    --role "Network Contributor" \
    --scope "/subscriptions/<subscription>/resourceGroups/$net_rg"
```

A new role assignment can take several minutes to become usable. Until it does, the operator reports the refusal and retries.

## Workload identity

`credentialsMode: Manual` with a service account issuer, which is what `ccoctl` installs. CCO cannot mint or copy anything here. It writes the operator's secret only when the `CredentialsRequest` names a managed identity, and only you can create that identity: the operator has no credentials with which to create one for itself.

**Step 1: create the identity and trust the operator's ServiceAccount.**

```bash
rg=<resource group holding the Route Server and the router nodes' interfaces>
issuer=$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}')
subject=system:serviceaccount:openshift-bgp-cloud-connector:openshift-bgp-cloud-connector-controller-manager

az identity create -g "$rg" -n bgp-cloud-connector
az identity federated-credential create -g "$rg" --identity-name bgp-cloud-connector \
    --name bgp-cloud-connector --issuer "$issuer" --subject "$subject" --audiences openshift
```

The subject names the namespace the operator runs in; change it if you installed somewhere other than `openshift-bgp-cloud-connector`.

**Step 2: give the identity a role** on the resource groups holding the Route Server and the router nodes' interfaces (on a default install, one group). `Network Contributor` on the group is what the operator has been tested with. A custom role with only the six actions above is not enough: writing an interface that sits in a subnet and a load balancer backend pool also needs the `join` actions on those, which Azure checks as a linked scope.

**Step 3: give the operator the identity.**

- **Installing from OperatorHub:** the console asks for the Azure Client ID, Tenant ID and Subscription ID, because the CSV declares `features.operators.openshift.io/token-auth-azure: "true"`, and sets them on the Subscription for you.
- **Installing by hand:** put them in the Subscription:

  ```yaml
  spec:
    config:
      env:
      - name: CLIENTID
        value: <the identity's client id>
      - name: TENANTID
        value: <tenant id>
      - name: SUBSCRIPTIONID
        value: <subscription id>
  ```

The operator then adds `azureClientID`, `azureTenantID`, `azureSubscriptionID` and `azureRegion` to its `CredentialsRequest`, and CCO writes a secret naming the identity and the token file. CCO refuses a request without a region and the console does not ask for one, so the operator takes it from `REGION` if the Subscription sets it, otherwise from the region the request already names, otherwise from the nodes' `topology.kubernetes.io/region` label.

All three of `CLIENTID`, `TENANTID` and `SUBSCRIPTIONID` are needed. With only some of them the operator sends none, because CCO fails a request that names part of an identity, and the `WaitingForCloudCredentials` message names the ones missing.

The variables are read from the operator's environment, so changing them needs a new pod. Setting them through the Subscription changes the Deployment and rolls the pod; the operator updates its existing `CredentialsRequest` on the next pass.

Use Manual approval for the Subscription, as the console suggests on these clusters. A later release may need permissions the identity does not yet hold, and Manual approval gives you the chance to grant them before upgrading.

## ARO with managed identities

ARO classic built with managed identities is workload identity, so everything in [Workload identity](#workload-identity) applies, with one addition.

ARO puts the cluster's VMs and network interfaces in a managed resource group (`aro-<cluster>` by default) behind a deny assignment. The deny assignment lets through only the cluster's platform identities and the ARO resource provider. An identity you create for the operator cannot write the router nodes' interfaces, whatever role it holds.

So on ARO the operator writes interfaces as the `machine-api` platform identity, and uses its own identity for everything else.

**Step 1: create the operator's identity** as in [Workload identity](#workload-identity), in the cluster's resource group (the one holding the cluster resource and the virtual network), with `Network Contributor` there so it can manage the Route Server.

**Step 2: trust the operator's ServiceAccount on the `machine-api` identity as well.**

```bash
az identity federated-credential create -g "$rg" --identity-name <machine-api identity> \
    --name bgp-cloud-connector --issuer "$issuer" --subject "$subject" --audiences openshift
nic_client_id=$(az identity show -g "$rg" -n <machine-api identity> --query clientId -o tsv)
```

The platform identities are the ones you named when you created the cluster; `az aro show` lists them under `platformWorkloadIdentityProfile`.

**Step 3: give the operator its identity** through the Subscription, as in [Workload identity](#workload-identity).

**Step 4: name the `machine-api` identity in the `BGPCloudConfiguration`:**

```yaml
spec:
  azure:
    networkInterfaceClientID: <nic_client_id>
```

The operator then makes network interface calls as that identity, exchanging its projected ServiceAccount token for it, in the tenant named in its own secret. Route Server calls keep using the operator's own identity. Leave `networkInterfaceClientID` unset everywhere else: without a deny assignment one identity reaches both.

See [custom-resources.md](custom-resources.md) for the full `spec.azure` field reference.

## Troubleshooting

The operator reports credential state through the `CloudEndpointsDiscovered` condition on `BGPCloudConfiguration`:

| Reason | Meaning | What to do |
|:---|:---|:---|
| `WaitingForCloudCredentials` | The operator has asked CCO for credentials and the secret has not been written. It requeues every 10 seconds. | On a workload identity cluster, the message names any of `CLIENTID`, `TENANTID` and `SUBSCRIPTIONID` that are unset; CCO writes nothing for a request that names no identity. If all three are set, check the `CredentialsRequest`'s status in `openshift-cloud-credential-operator`. |
| `CloudCredentialsInvalid` | A credential was found and Azure refused it when the operator asked for a token. | Check the identity's federated credential: issuer, subject and audience `openshift` must match exactly. For a service principal, check the secret CCO wrote. |
| `CloudDiscoveryFailed` | The credential works and a Route Server or interface call failed. | An authorisation error here means the identity lacks a role on the resource group named in the error. On ARO, a refusal mentioning a deny assignment means `networkInterfaceClientID` is unset or names an identity the deny assignment does not let through. |

Inspect the live conditions:

```bash
oc get bgpcloudconfiguration cluster -o jsonpath='{.status.conditions}' | jq .
```
