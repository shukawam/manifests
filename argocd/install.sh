#! /bin/bash

helm install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    -f values.yaml
