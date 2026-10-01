#!/usr/bin/env python3
"""Render the real Argo Helm inputs and check candidate isolation, offline after download."""
import argparse
from pathlib import Path
import subprocess
import tempfile

import yaml


ROOT = Path(__file__).resolve().parents[1]


def need(value, message):
    if not value:
        raise ValueError(message)


def render(app, chart):
    source = app["spec"]["sources"][0]
    helm = source["helm"]
    cmd = ["helm", "template", helm.get("releaseName", app["metadata"]["name"]), str(chart),
           "--namespace", app["spec"]["destination"]["namespace"],
           "--api-versions", "cert-manager.io/v1"]
    for value_file in helm["valueFiles"]:
        need(value_file.startswith("$values/"), "unsupported values source")
        cmd += ["-f", str(ROOT / value_file.removeprefix("$values/"))]
    return [v for v in yaml.safe_load_all(subprocess.check_output(cmd, text=True)) if v]


def one(objects, kind):
    matches = [obj for obj in objects if obj["kind"] == kind]
    need(len(matches) == 1, "expected one " + kind)
    return matches[0]


def check(stable, candidate, app, route):
    need("automated" not in app["spec"]["syncPolicy"], "candidate must require manual sync")
    need(not any(o["kind"] in ("Certificate", "ServiceAccount", "Secret", "Ingress", "HTTPRoute") for o in candidate),
         "candidate must not own shared identity/certificates or a public route")
    old, new = one(stable, "Deployment"), one(candidate, "Deployment")
    pod_old, pod_new = old["spec"]["template"]["spec"], new["spec"]["template"]["spec"]
    need(old["metadata"]["name"] != new["metadata"]["name"], "deployment names collide")
    need(new["metadata"]["name"] == "kong-ai-gateway-candidate", "unexpected candidate name")
    need(pod_old["serviceAccountName"] == pod_new["serviceAccountName"], "Workload Identity KSA differs")
    def env(pod):
        return {e["name"]: e.get("value") for c in pod["containers"] if c["name"] == "proxy" for e in c["env"]}
    for key in ("KONG_CLUSTER_CONTROL_PLANE", "KONG_CLUSTER_TELEMETRY_ENDPOINT", "KONG_CLUSTER_SERVER_NAME"):
        need(env(pod_old)[key] == env(pod_new)[key], "Konnect endpoint differs: " + key)
    certs = [o["spec"]["secretName"] for o in stable if o["kind"] == "Certificate"]
    mounted = {v.get("secret", {}).get("secretName") for v in pod_new["volumes"]}
    need(len(certs) == 1 and certs[0] in mounted, "registered cluster certificate is not reused")
    proxy = next(c for c in pod_new["containers"] if c["name"] == "proxy")
    mounts = {v["name"]: v["mountPath"] for v in proxy["volumeMounts"]}
    need(env(pod_new)["KONG_CLUSTER_CERT"] == mounts[certs[0]] + "/tls.crt", "certificate path not mounted")
    need(env(pod_new)["KONG_CLUSTER_CERT_KEY"] == mounts[certs[0]] + "/tls.key", "key path not mounted")
    need(proxy["readinessProbe"]["httpGet"]["path"].split("?")[0] == "/status/ready", "readiness does not gate configuration")
    need(pod_new["terminationGracePeriodSeconds"] >= 3630, "stream draining grace period too short")
    need(env(pod_new).get("KONG_NGINX_MAIN_WORKER_SHUTDOWN_TIMEOUT") == "3600s", "NGINX draining timeout differs")
    need(proxy["lifecycle"]["preStop"]["exec"]["command"] == ["kong", "quit", "--wait=15", "--timeout=3600"], "graceful quit timeout differs")
    old_svc, new_svc = one(stable, "Service"), one(candidate, "Service")
    need(new_svc["spec"]["type"] == "ClusterIP", "candidate must stay internal")
    for svc, yes, no in ((old_svc, old, new), (new_svc, new, old)):
        selector = svc["spec"]["selector"]
        need(all(yes["spec"]["template"]["metadata"]["labels"].get(k) == v for k, v in selector.items()), "service selects wrong pods")
        need(not all(no["spec"]["template"]["metadata"]["labels"].get(k) == v for k, v in selector.items()), "service mixes old/new pods")
    names = {r["name"] for rule in route["spec"]["rules"] for r in rule.get("backendRefs", [])}
    need(names == {old_svc["metadata"]["name"]}, "public route must still use stable only")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chart", type=Path, help="cached kong-ai-gateway chart .tgz; otherwise pull the pinned version")
    args = parser.parse_args()
    apps = [yaml.safe_load((ROOT / ("apps/" + name + ".yaml")).read_text())
            for name in ("kong-ai-gateway", "kong-ai-gateway-candidate")]
    versions = {app["spec"]["sources"][0]["targetRevision"] for app in apps}
    need(len(versions) == 1, "compare the same chart version")
    with tempfile.TemporaryDirectory(prefix="aigw-chart-") as tmp:
        chart = args.chart
        version = str(next(iter(versions)))
        if chart is None:
            subprocess.run(["helm", "pull", "kong-ai-gateway", "--repo", "https://charts.konghq.com",
                            "--version", version, "--destination", tmp], check=True)
            chart = Path(tmp) / ("kong-ai-gateway-" + version + ".tgz")
        metadata = yaml.safe_load(subprocess.check_output(["helm", "show", "chart", str(chart)], text=True))
        need(metadata["name"] == "kong-ai-gateway" and str(metadata["version"]) == version, "wrong cached chart")
        check(render(apps[0], chart), render(apps[1], chart), apps[1],
              yaml.safe_load((ROOT / "platform/kong-gateway/httproute-aigw.yaml").read_text()))
    print("PASS: candidate rendering, selectors, certificate, identity, readiness and stable routing")


if __name__ == "__main__":
    main()
