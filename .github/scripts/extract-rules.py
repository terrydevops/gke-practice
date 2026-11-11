#!/usr/bin/env python3
"""Write each PrometheusRule in a rendered stream as a Prometheus rule file.

promtool reads rule files ({groups: [...]}), not PrometheusRule objects. This
reads rendered manifests (kustomize build output, several documents) on stdin
and writes the spec of every PrometheusRule to <dir>/<namespace>-<name>.yaml,
the name the tests in gitops/tests/rules use in rule_files. The same object
rendered from two directories is written once.

Usage: kustomize build ... | extract-rules.py <dir>
"""
import os
import sys

import yaml

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
written = set()
for doc in yaml.safe_load_all(sys.stdin):
    if not doc or doc.get("kind") != "PrometheusRule":
        continue
    meta = doc["metadata"]
    name = "%s-%s.yaml" % (meta.get("namespace", "default"), meta["name"])
    with open(os.path.join(out, name), "w") as f:
        yaml.safe_dump({"groups": doc["spec"]["groups"]}, f, sort_keys=False)
    written.add(name)
if not written:
    sys.exit("no PrometheusRule in the input")
print("\n".join(sorted(written)))
