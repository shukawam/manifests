#! /bin/bash

helm upgrade argocd argo/argo-cd \
    -f values.yaml
