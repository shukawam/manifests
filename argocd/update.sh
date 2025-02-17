#! /bin/bash

helm upgrade argocd argo/argo-cd \
    --namespace argocd \
    -f values.yaml
