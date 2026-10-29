# Chaos experiments

Fault injection is started by hand, never by Flux: no Kustomization points here. Chaos Mesh itself is
in `infrastructure/controllers/chaos-mesh.yaml`; it only reaches namespaces annotated
`chaos-mesh.org/inject: enabled`, which `tenants/base` sets on tenant namespaces.

| File | Fault | Expected |
|---|---|---|
| `pod-kill-dev.yaml` | kill whoami-dev's only pod | a new pod by itself; a short dent in dev availability |
| `pod-kill-staging.yaml` | kill one of whoami-staging's two pods | staging availability does not move |
| `network-delay.yaml` | +300ms on everything whoami-dev sends, 5 minutes | dev latency SLO burns, availability does not |
| `cpu-stress.yaml` | one CPU worker at full load in whoami-dev, 5 minutes | throttled at its 100m limit |

## Run one

```bash
kubectl apply --dry-run=server -f gitops/chaos/network-delay.yaml   # the schema check CI cannot do
kubectl apply -f gitops/chaos/network-delay.yaml
kubectl -n chaos-mesh get networkchaos                                # Injected, then Finished
```

Watch it in the Pyrra UI or the "Pyrra - Detail" dashboard in Grafana (see "Monitoring" in
`gitops/README.md`), and in the Chaos Mesh dashboard.

Experiments with a `duration` recover by themselves when it runs out. To stop one early, or to run it
again, delete it:

```bash
kubectl delete -f gitops/chaos/network-delay.yaml
```

Before a teardown, check that none is left: `kubectl get podchaos,networkchaos,stresschaos -A`.
