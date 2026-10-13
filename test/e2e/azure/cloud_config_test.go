/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package azure_e2e

import "testing"

func TestTenantFromCloudConfig(t *testing.T) {
	for _, tc := range []struct {
		name, config, want string
		wantErr            bool
	}{
		{
			name:   "ARO HCP",
			config: `{"cloud":"AzurePublicCloud","tenantId":"tenant-a","resourceGroup":"aro-c","vnetResourceGroup":"c"}`,
			want:   "tenant-a",
		},
		{name: "no tenant", config: `{"cloud":"AzurePublicCloud"}`, wantErr: true},
		{name: "empty tenant", config: `{"tenantId":""}`, wantErr: true},
		{name: "not JSON", config: `cloud: AzurePublicCloud`, wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := tenantFromCloudConfig(tc.config)
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, want error %t", err, tc.wantErr)
			}
			if got != tc.want {
				t.Fatalf("tenant = %q, want %q", got, tc.want)
			}
		})
	}
}
