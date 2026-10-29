#!/usr/bin/env python3
"""Fail on a ${...} that Flux postBuild would not be able to fill in.

kustomize-controller substitutes ${var} in what a Kustomization with postBuild
renders, and in strict mode an unset variable without a default fails the whole
Kustomization, and with it everything that dependsOn it. kustomize build and
kubeconform do not see this, so a dashboard's ${datasource} once passed CI and
then held up infra-configs.

For each Flux Kustomization under gitops/clusters/ that has postBuild, this
renders its path, skips objects annotated
kustomize.toolkit.fluxcd.io/substitute: disabled, and checks every reference
against the variables it would get. Kustomizations rendered from there (the
tenant syncs) are followed with their own variables.

Usage: check-flux-substitution.py <cluster directory>
"""
import glob
import os
import re
import subprocess
import sys

import yaml

# substituteFrom sources that are not in git, with the keys they hold.
# cluster-vars is created by hand at bootstrap (gitops/README.md, "Bootstrap").
# The optional cluster_viewer_N keys are always referenced with a default.
EXTERNAL_SOURCES = {
    ("ConfigMap", "cluster-vars"): {"cluster_admin", "proxy_only_cidr"},
}

KS_API = "kustomize.toolkit.fluxcd.io/"
DISABLED = "kustomize.toolkit.fluxcd.io/substitute"
# ${name} or ${name<operator>...}; $${...} is Flux's escape for a literal.
REF = re.compile(r"(?<!\$)\$\{([^}]*)\}")
NAME = re.compile(r"[_A-Za-z][_A-Za-z0-9]*")


def flux_kustomizations(docs):
    for d in docs:
        if d and d.get("kind") == "Kustomization" and str(d.get("apiVersion", "")).startswith(KS_API):
            yield d


def variables(ks):
    post = ks["spec"].get("postBuild") or {}
    names = set((post.get("substitute") or {}).keys())
    for src in post.get("substituteFrom") or []:
        key = (src.get("kind"), src.get("name"))
        if key not in EXTERNAL_SOURCES:
            if src.get("optional"):
                continue
            raise SystemExit(f"unknown substituteFrom {key}: add its keys to EXTERNAL_SOURCES")
        names |= EXTERNAL_SOURCES[key]
    return names


def bad_refs(text, names):
    for m in REF.finditer(text):
        body = m.group(1)
        n = NAME.match(body)
        if not n:
            yield m.group(0), "not a variable name"
            continue
        rest = body[n.end():]
        if rest == "" and n.group(0) not in names:
            yield m.group(0), "not set, no default"


def check(ks, names, failures, seen):
    name = ks["metadata"]["name"]
    path = ks["spec"]["path"].lstrip("./")
    if (name, path) in seen:
        return
    seen.add((name, path))
    out = subprocess.run(["kustomize", "build", path], capture_output=True, text=True)
    if out.returncode != 0:
        failures.append(f"{name}: kustomize build {path} failed:\n{out.stderr}")
        return
    count = 0
    for raw in re.split(r"^---$", out.stdout, flags=re.M):
        doc = yaml.safe_load(raw)
        if not doc:
            continue
        ann = (doc.get("metadata") or {}).get("annotations") or {}
        if ann.get(DISABLED) == "disabled":
            continue
        count += 1
        what = f'{doc.get("kind")}/{(doc.get("metadata") or {}).get("name")}'
        for ref, why in sorted(set(bad_refs(raw, names))):
            failures.append(f"{name} ({path}): {what}: {ref} {why}")
    print(f"== {name}: {path}, {count} objects, variables: {', '.join(sorted(names)) or '-'}")
    # Follow Kustomizations this one renders, after its own substitution.
    # Values from git are filled in; values kept outside git become <name>.
    literal = ks["spec"]["postBuild"].get("substitute") or {}
    for child in flux_kustomizations(yaml.safe_load_all(out.stdout)):
        if not child["spec"].get("postBuild"):
            continue
        text = yaml.safe_dump(child)
        for v in names:
            text = text.replace("${" + v + "}", str(literal.get(v, f"<{v}>")))
        child = yaml.safe_load(text)
        check(child, variables(child), failures, seen)


def main():
    cluster = sys.argv[1]
    failures, seen = [], set()
    files = sorted(glob.glob(os.path.join(cluster, "*.yaml")))
    for f in files:
        with open(f) as fh:
            for ks in flux_kustomizations(yaml.safe_load_all(fh)):
                if ks["spec"].get("postBuild"):
                    check(ks, variables(ks), failures, seen)
    if failures:
        print("\nFAILED: Flux postBuild would not substitute these.")
        print("Define the variable, give it a default (${name:=value}), escape it as $${name},")
        print(f"or annotate the object {DISABLED}: disabled.")
        for line in failures:
            print("  " + line)
        sys.exit(1)


if __name__ == "__main__":
    main()
