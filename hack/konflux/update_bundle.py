#!/usr/bin/env python3

import os
import sys

from ruamel.yaml import YAML

manifests_dir = os.getenv('MANIFESTS_DIR', '')
if not manifests_dir:
    print('ERROR: MANIFESTS_DIR is not set')
    sys.exit(1)
operator_pullspec = os.getenv('OPERATOR_IMAGE_PULLSPEC', '')
if not operator_pullspec:
    print('ERROR: OPERATOR_IMAGE_PULLSPEC is not set')
    sys.exit(1)
csv_file = os.path.join(manifests_dir, 'bgp-cloud-connector.clusterserviceversion.yaml')

with open(csv_file, 'r') as f:
    content = f.read()

content = content.replace('controller:latest', f'"{operator_pullspec}"')

yaml = YAML()
yaml.preserve_quotes = True
yaml.width = 4096

csv = yaml.load(content)

with open(csv_file, 'w') as f:
    yaml.dump(csv, f)
