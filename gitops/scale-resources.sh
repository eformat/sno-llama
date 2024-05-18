#!/bin/bash

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color
readonly RUN_DIR=$(pwd)

# scale the RHOAI operaror down
oc -n redhat-ods-operator scale deployment/rhods-operator --replicas=0

# reduce deployment count
oc -n redhat-ods-applications scale deployment rhods-dashboard --replicas=1
oc -n redhat-ods-applications scale deployment odh-model-controller --replicas=1
oc -n redhat-ods-applications scale deployment modelmesh-controller --replicas=1
oc -n redhat-ods-applications scale deployment codeflare-operator-manager --replicas=0

# scale istio replicas
oc -n istio-system scale $(oc -n istio-system get deployment -o name) --replicas=1

# Knative - once running - scale the operator to zero else it just scales it all back up
oc -n openshift-operators scale deployments knative-openshift --replicas=0
oc -n openshift-operators scale deployment knative-openshift-ingress --replicas=0
oc -n openshift-operators scale deployment knative-operator-webhook --replicas=0
oc delete hpa --all -n knative-serving

# scale knative serving to zero, then to 1 replica
oc -n knative-serving scale $(oc -n knative-serving get deployment -o name) --replicas=0
oc patch deployment/istio-egressgateway -n istio-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"istio-proxy","resources":{"limits":{"cpu":"500m","memory":"1Gi"},"requests":{"cpu":"10m","memory":"128Mi"}}}]}}}}' --type=strategic
oc patch deployment/istio-ingressgateway -n istio-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"istio-proxy","resources":{"limits":{"cpu":"500m","memory":"1Gi"},"requests":{"cpu":"10m","memory":"128Mi"}}}]}}}}' --type=strategic
oc -n knative-serving scale $(oc -n knative-serving get deployment -o name) --replicas=1

# delete any pending pods
oc get pods -n knative-serving | grep Pending | awk '{system("oc -n knative-serving delete pod --force " $1 )}'
