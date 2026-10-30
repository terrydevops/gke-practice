# Chaos experiments

Fault injection is started by hand, never by Flux: no Kustomization points here. Chaos Mesh itself is
in `infrastructure/controllers/chaos-mesh.yaml`; it only reaches namespaces annotated
`chaos-mesh.org/inject: enabled`, which `tenants/base` sets on tenant namespaces.

| File | Fault | Seen on 2026-10-29 |
|---|---|---|
| `pod-kill-dev.yaml` | kill whoami-dev's only pod | replacement Ready after 17s, one failed probe; dev availability dented, no alert |
| `pod-kill-staging.yaml` | kill one of whoami-staging's two pods | replacement Ready after 10s, no failed probe; staging SLOs did not move |
| `network-delay.yaml` | +300ms on everything whoami-dev sends, 5 minutes | probe time 20ms to about 600ms (the handshake and the answer are both delayed), through the Service; dev latency burn 1.0, availability and staging untouched; back to 20ms when it ran out |
| `cpu-stress.yaml` | one CPU worker at full load in whoami-dev, 5 minutes | CPU pinned at the 100m limit, 95-100% of periods throttled; probe time 20ms to 30-55ms, so **no SLO moved**: whoami needs too little CPU to show it |

The latency fast-burn alert did not fire for the 5-minute delay, as expected: it needs the 15-minute
window above 14 x 5%, about ten minutes of slow answers.

Works on this cluster (Container-Optimized OS, containerd, cgroup v2, Dataplane V2) with Chaos Mesh
2.8.4: network delay through a ClusterIP Service, and CPU stress with the daemon privileged.

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

## Load tests

`load/` holds k6 load tests, also run by hand. They make nodes busy and can add one, so not during a
demo.

```bash
kubectl apply -f gitops/chaos/load/esplora-baseline.yaml
kubectl -n load get pods -w                                      # ten pods, about six minutes
kubectl -n load logs -l job-name=esplora-baseline --tail=1        # one JSON line per pod
kubectl delete -f gitops/chaos/load/esplora-baseline.yaml         # also removes the esplora NetworkPolicy
```

While it runs, watch esplora-0's CPU per container (`kubectl -n esplora top pod --containers`), the
"Esplora chains" dashboard and the `esplora-bitcoin-*` objectives in Pyrra.
