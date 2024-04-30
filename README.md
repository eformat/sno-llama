# 🦙🦙🦙 SNO on Spot running LLM's 🦙🦙🦙

A simple method to provision RHOAI on Single Node OpenShift to try out different quantized LLM's including meta's llama2,3 and ibm/redhat granite models.

We use a g6.4xlarge on aws spot - which comes with a modern Nvidia L4 (24GB), 16 vCPU, 64 GiB RAM.

Running OpenShift 4.15 Single Node. We configure Nvidia time slicing to parallel share the GPU for running jupyter notebooks and model serving.

## Install OpenShift

Install OCP using [SNO on SPOT](https://developers.redhat.com/blog/2023/02/08/sno-spot).

```bash
export AWS_PROFILE=sno-llama
export AWS_DEFAULT_REGION=us-east-2
export AWS_DEFAULT_ZONES=["us-east-2c"]
export CLUSTER_NAME=sno
export BASE_DOMAIN=sandbox.opentlc.com
export PULL_SECRET=$(cat ~/tmp/pull-secret)
export SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
export INSTANCE_TYPE=g6.4xlarge
export ROOT_VOLUME_SIZE=200
export OPENSHIFT_VERSION=4.15.9

mkdir -p ~/tmp/sno-${AWS_PROFILE} && cd ~/tmp/sno-${AWS_PROFILE}

curl -Ls https://raw.githubusercontent.com/eformat/sno-for-100/main/sno-for-100.sh | bash -s -- -d
```

## Configure OpenShift and Install RHOAI

Configure OAuth with htpasswd.

```bash
export CLUSTER_DOMAIN=apps.sno.sandbox.opentlc.com
oc login --server=https://api.${CLUSTER_DOMAIN##apps.}:6443 -u kubeadmin -p <PASSWORD>

export ADMIN_PASSWORD=<ADMIN PASSWORD>
htpasswd -bBc /tmp/htpasswd admin ${ADMIN_PASSWORD}
htpasswd -bB /tmp/htpasswd admin2 ${ADMIN2_PASSWORD}

oc adm policy add-cluster-role-to-user cluster-admin admin
oc adm policy add-cluster-role-to-user cluster-admin admin2
oc delete secret htpasswdidp-secret -n openshift-config
oc create secret generic htpasswdidp-secret -n openshift-config --from-file=/tmp/htpasswd

cat << EOF > /tmp/htpasswd.yaml
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: htpasswd_provider
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpasswdidp-secret
EOF
oc apply -f /tmp/htpasswd.yaml -n openshift-config

oc login --server=https://api.${CLUSTER_DOMAIN##apps.}:6443 -u admin -p ${ADMIN_PASSWORD}
oc delete secret kubeadmin -n kube-system
```

Configure Let's Encrypt cert for Ingress.

```bash
export LE_API=$(oc whoami --show-server | cut -f 2 -d ':' | cut -f 3 -d '/' | sed 's/-api././')
export LE_WILDCARD=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}')
cd ~/git && git clone https://github.com/Neilpang/acme.sh.git
~/git/acme.sh/acme.sh --issue --dns dns_aws -d ${LE_API} -d *.${LE_WILDCARD} --dnssleep 100 --force --insecure
oc -n openshift-ingress delete secret router-certs
oc -n openshift-ingress create secret tls router-certs --cert=/home/$USER/.acme.sh/${LE_API}/fullchain.cer --key=/home/$USER/.acme.sh/${LE_API}/${LE_API}.key
oc -n openshift-ingress-operator patch ingresscontroller default --patch '{"spec": { "defaultCertificate": { "name": "router-certs"}}}' --type=merge
```

Add 200GB extra Volume. Use ThinLVM from ODS and set as default storage class. 

```bash
export AWS_ACCESS_KEY_ID=<AWS_ACCESS_KEY_ID>
export AWS_SECRET_ACCESS_KEY=<AWS_SECRET_ACCESS_KEY>

export INSTANCE_ID=$(aws ec2 describe-instances \
--query "Reservations[].Instances[].InstanceId" \
--filters "Name=tag-value,Values=$CLUSTER_NAME-*-master-0" "Name=instance-state-name,Values=running" \
--output text)

export AWS_ZONE=$(aws ec2 describe-instances \
--query "Reservations[].Instances[].Placement.AvailabilityZone" \
--filters "Name=tag-value,Values=$CLUSTER_NAME-*-master-0" "Name=instance-state-name,Values=running" \
--output text)

vol=$(aws ec2 create-volume \
--availability-zone ${AWS_ZONE} \
--volume-type gp3 \
--size 200 \
--region=${AWS_DEFAULT_REGION})

aws ec2 attach-volume \
--volume-id $(echo ${vol} | jq -r '.VolumeId') \
--instance-id ${INSTANCE_ID} \
--device /dev/sdf

cat <<EOF | oc apply -f-
kind: Namespace
apiVersion: v1
metadata:
  name: openshift-storage
EOF

cat <<'EOF' | oc apply -f-
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-storage
  namespace: openshift-storage
spec:
  targetNamespaces:
  - openshift-storage
EOF

cat <<EOF | oc apply -f-
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/odf-lvm-operator.openshift-storage: ''
  name: lvms-operator
  namespace: openshift-storage
spec:
  channel: stable-4.15
  installPlanApproval: Automatic
  name: lvms-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

watch oc get csv -A
```

Make sure we have sno-lvm on the second attached disk only as spot conversion makes ami disk bigger so can get allocated to lvm unintentionally.

Obtain disk-by-path for second disk `nvme2n1`

```bash
oc debug node/ip-10-0-83-218.us-east-2.compute.internal
chroot /host
lsblk
ls -lart /dev/disk/by-path/
```

```bash
cat <<EOF | oc apply -f-
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
 name: sno-lvm
 namespace: openshift-storage
spec:
 storage:
   deviceClasses:
     - name: vgsno
       thinPoolConfig:
         name: thin-pool-1
         overprovisionRatio: 10
         sizePercent: 90
       deviceSelector:
         paths:
         - /dev/disk/by-path/pci-0000:33:00.0-nvme-1

EOF

oc annotate sc/lvms-vgsno storageclass.kubernetes.io/is-default-class=true
oc annotate sc/gp3-csi storageclass.kubernetes.io/is-default-class-
```

We will also use noobaa multicloud gateway for s3 storage.

```bash
cat <<EOF | oc apply -f-
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: openshift-storage
spec:
  channel: stable-4.15
  installPlanApproval: Automatic
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

watch oc -n openshift-storage get csv
```

```bash
cat <<EOF | oc apply -f-
apiVersion: odf.openshift.io/v1alpha1
kind: StorageSystem
metadata:
  name: ocs-storagecluster-storagesystem
  namespace: openshift-storage
spec:
  kind: storagecluster.ocs.openshift.io/v1
  name: ocs-storagecluster
  namespace: openshift-storage
EOF
```

Remove the CPU Limits for on Nooba so we can better utilize resources.

```bash
cat <<EOF | oc apply -f-
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  multiCloudGateway:
    dbStorageClassName: lvms-vgsno
    endpoints:
      maxCount: 1
      minCount: 1
    reconcileStrategy: standalone
  resourceProfile: balanced
  resources:
    noobaa-core:
      requests:
        cpu: 500m
        memory: 4Gi
    noobaa-db:
      requests:
        cpu: 500m
        memory: 4Gi
    noobaa-endpoint:
      requests:
        cpu: 500m
        memory: 4Gi
EOF
```

Check noobaa status and how to connect to s3.

```bash
oc project openshift-storage
noobaa status
oc describe noobaa
```

Try out some performance enhancements for your SNO cluster.

- Encapsulating mount namespaces
- Configuring crun as the default container runtime
- 500 pods max
- We want to set up custom LVM Configuration else we can get annoying PVID issues in RHEL9 when the SPOT instance reboots. [See here for details.](https://access.redhat.com/solutions/6889951#FN.1).
- Disable CRIO wipe for SNO

Run this post install, your SNO will reboot.


```bash
cat <<EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-kubens-master
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - enabled: true
        name: kubens.service
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-kubens-worker
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - enabled: true
        name: kubens.service
---
apiVersion: machineconfiguration.openshift.io/v1
kind: ContainerRuntimeConfig
metadata:
 name: enable-crun-master
spec:
 machineConfigPoolSelector:
   matchLabels:
     pools.operator.machineconfiguration.openshift.io/master: ""
 containerRuntimeConfig:
   defaultRuntime: crun
---
apiVersion: machineconfiguration.openshift.io/v1
kind: ContainerRuntimeConfig
metadata:
 name: enable-crun-worker
spec:
 machineConfigPoolSelector:
   matchLabels:
     pools.operator.machineconfiguration.openshift.io/worker: ""
 containerRuntimeConfig:
   defaultRuntime: crun
---
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: set-max-pods
spec:
  machineConfigPoolSelector:
    matchLabels:
      custom-kubelet: large-pods
  kubeletConfig:
    podsPerCore: 0
    maxPods: 500
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  labels:
    custom-kubelet: large-pods
  name: master
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-lvm-conf
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - contents:
            compression: gzip
            source: data:;base64,H4sIAAAAAAAC/zyNQarDMAwF9z6F8Pob/gVyklKMoiqxiWqltpNNyN2LQujuMUIzpGXKMxyne/GeiRscDgBgaxxvMmVhGOD/4o2xUoqTVjsXfHODATyKeHc6FFHCnrWYUfQSj0jLttpqiUVszKIjyp3qKZdIiWmJutqvGR/gw8f/gQ8Bt66h8oq5enhahXref5VvAAAA///jFypswgAAAA==
          mode: 420
          overwrite: true
          path: /etc/lvm/lvm.conf
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-crio-disable-wipe-master
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - contents:
            source: data:text/plain;charset=utf-8;base64,W2NyaW9dCmNsZWFuX3NodXRkb3duX2ZpbGUgPSAiIgo=
          mode: 420
          path: /etc/crio/crio.conf.d/99-crio-disable-wipe.toml
EOF
```

Configure the Node Feature Discovery Operator so we can discover the GPU.

```bash
cat <<EOF | oc create -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  annotations:
    olm.providedAPIs: NodeFeatureDiscovery.v1.nfd.openshift.io,NodeFeatureRule.v1alpha1.nfd.openshift.io,NodeResourceTopology.v1alpha1.topology.node.k8s.io,NodeResourceTopology.v1alpha2.topology.node.k8s.io
  generateName: openshift-nfd-
  name: openshift-nfd-og
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
  upgradeStrategy: Default
EOF
```

```bash
cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

```bash
watch oc get csv -A
```

```bash
cat <<'EOF' | oc create -f -
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  finalizers:
  - foreground-deletion
  name: nfd-instance
  namespace: openshift-nfd
spec:
  instance: ""
  operand:
    image: registry.redhat.io/openshift4/ose-node-feature-discovery-rhel9@sha256:28cdc37abe476ed523ff916a52278ba08c11f2ef6ccc9d40420934eded2fe401
    servicePort: 12000
  prunerOnDelete: false
  topologyUpdater: false
  workerConfig:
    configData: "core:\n#  labelWhiteList:\n#  noPublish: false\n  sleepInterval:
      60s\n#  sources: [all]\n#  klog:\n#    addDirHeader: false\n#    alsologtostderr:
      false\n#    logBacktraceAt:\n#    logtostderr: true\n#    skipHeaders: false\n#
      \   stderrthreshold: 2\n#    v: 0\n#    vmodule:\n##   NOTE: the following options
      are not dynamically run-time \n##          configurable and require a nfd-worker
      restart to take effect\n##          after being changed\n#    logDir:\n#    logFile:\n#
      \   logFileMaxSize: 1800\n#    skipLogHeaders: false\nsources:\n#  cpu:\n#    cpuid:\n##
      \    NOTE: whitelist has priority over blacklist\n#      attributeBlacklist:\n#
      \       - \"BMI1\"\n#        - \"BMI2\"\n#        - \"CLMUL\"\n#        - \"CMOV\"\n#
      \       - \"CX16\"\n#        - \"ERMS\"\n#        - \"F16C\"\n#        - \"HTT\"\n#
      \       - \"LZCNT\"\n#        - \"MMX\"\n#        - \"MMXEXT\"\n#        - \"NX\"\n#
      \       - \"POPCNT\"\n#        - \"RDRAND\"\n#        - \"RDSEED\"\n#        -
      \"RDTSCP\"\n#        - \"SGX\"\n#        - \"SSE\"\n#        - \"SSE2\"\n#        -
      \"SSE3\"\n#        - \"SSE4.1\"\n#        - \"SSE4.2\"\n#        - \"SSSE3\"\n#
      \     attributeWhitelist:\n#  kernel:\n#    kconfigFile: \"/path/to/kconfig\"\n#
      \   configOpts:\n#      - \"NO_HZ\"\n#      - \"X86\"\n#      - \"DMI\"\n  pci:\n
      \   deviceClassWhitelist:\n      - \"0200\"\n      - \"03\"\n      - \"12\"\n
      \   deviceLabelFields:\n#      - \"class\"\n      - \"vendor\"\n#      - \"device\"\n#
      \     - \"subsystem_vendor\"\n#      - \"subsystem_device\"\n#  usb:\n#    deviceClassWhitelist:\n#
      \     - \"0e\"\n#      - \"ef\"\n#      - \"fe\"\n#      - \"ff\"\n#    deviceLabelFields:\n#
      \     - \"class\"\n#      - \"vendor\"\n#      - \"device\"\n#  custom:\n#    -
      name: \"my.kernel.feature\"\n#      matchOn:\n#        - loadedKMod: [\"example_kmod1\",
      \"example_kmod2\"]\n#    - name: \"my.pci.feature\"\n#      matchOn:\n#        -
      pciId:\n#            class: [\"0200\"]\n#            vendor: [\"15b3\"]\n#            device:
      [\"1014\", \"1017\"]\n#        - pciId :\n#            vendor: [\"8086\"]\n#
      \           device: [\"1000\", \"1100\"]\n#    - name: \"my.usb.feature\"\n#
      \     matchOn:\n#        - usbId:\n#          class: [\"ff\"]\n#          vendor:
      [\"03e7\"]\n#          device: [\"2485\"]\n#        - usbId:\n#          class:
      [\"fe\"]\n#          vendor: [\"1a6e\"]\n#          device: [\"089a\"]\n#    -
      name: \"my.combined.feature\"\n#      matchOn:\n#        - pciId:\n#            vendor:
      [\"15b3\"]\n#            device: [\"1014\", \"1017\"]\n#          loadedKMod
      : [\"vendor_kmod1\", \"vendor_kmod2\"]\n"
EOF
```

Configure the NVidia GPU Operator.

```bash
cat <<EOF | oc create -f -
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: nvidia-gpu-operator
spec:
 targetNamespaces:
 - nvidia-gpu-operator
EOF
```

```bash
oc get packagemanifest gpu-operator-certified -n openshift-marketplace -o jsonpath='{.status.defaultChannel}'
```

```bash
cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: "v23.9"
  installPlanApproval: Automatic
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
EOF
```

```bash
watch oc get csv -A
```

```bash
oc get csv -n nvidia-gpu-operator gpu-operator-certified.v23.9.2 -ojsonpath={.metadata.annotations.alm-examples} | jq .[0] | oc create -n nvidia-gpu-operator -f-
```

```bash
oc describe node | egrep 'Roles|pci' | grep -v master
oc describe node | sed '/Capacity/,/System/!d;/System/d'
```

Configure the NVidia GPU OpenShift UI Plugin.

```bash
helm repo add rh-ecosystem-edge https://rh-ecosystem-edge.github.io/console-plugin-nvidia-gpu
helm repo update rh-ecosystem-edge
helm install -n nvidia-gpu-operator console-plugin-nvidia-gpu rh-ecosystem-edge/console-plugin-nvidia-gpu
oc get consoles.operator.openshift.io cluster --output=jsonpath="{.spec.plugins}"
oc patch consoles.operator.openshift.io cluster --patch '[{"op": "add", "path": "/spec/plugins/-", "value": "console-plugin-nvidia-gpu" }]' --type=json
```

Configure the NVidia GPU for time slicing.

```bash
cat << EOF >> /tmp/time-slicing-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: nvidia-gpu-operator
data:
    nvidia-l4: |-
      version: v1
      flags:
        migStrategy: none
      sharing:
        timeSlicing:
          resources:
          - name: nvidia.com/gpu
            replicas: 4
EOF
oc apply -f /tmp/time-slicing-config.yaml

oc patch clusterpolicies.nvidia.com/gpu-cluster-policy \
    -n nvidia-gpu-operator --type merge \
    -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config"}}}}'

oc label node \
    --selector=nvidia.com/gpu.product=NVIDIA-L4 \
    nvidia.com/device-plugin.config=nvidia-l4
```

```bash
oc get events -n nvidia-gpu-operator --sort-by='.lastTimestamp'
oc describe node | sed '/Capacity/,/System/!d;/System/d'
```

Deploy Service Mesh, Serverless pre-requisites for Kserve.

```bash
cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/servicemeshoperator.openshift-operators: ""
  name: servicemeshoperator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: servicemeshoperator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/serverless-operator.openshift-serverless: ""
  name: serverless-operator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: serverless-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

```bash
watch oc -n openshift-operators get csv
```


Configure the RHOAI Data Science Pipelines operator v2.

```bash
WORKING_DIR=$(mktemp -d)
git clone https://github.com/opendatahub-io/data-science-pipelines-operator.git ${WORKING_DIR}
```

```bash
export ODH_NS=redhat-ods-operator
cat <<EOF | oc create -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${ODH_NS}
  labels:
    openshift.io/cluster-monitoring: "true"
EOF
```

```bash
cd ${WORKING_DIR}
make deploy OPERATOR_NS=${ODH_NS}
oc get pods -n ${ODH_NS}
```

Configure the RHOAI Operator.

```bash
cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: redhat-ods-operator-og
  namespace: redhat-ods-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/rhods-operator.redhat-ods-operator: ""
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

```bash
watch oc get csv -A
```

[Configure the RHOAI Data Science Cluster](https://github.com/opendatahub-io/opendatahub-operator#example-datasciencecluster)

```yaml
cat <<EOF | oc create -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
  namespace: redhat-ods-operator
spec:
  components:
    codeflare:
      managementState: Managed
    dashboard:
      managementState: Managed
    datasciencepipelines:
      managementState: Managed
    kserve:
      managementState: Managed
      serving:
      ingressGateway:
        certificate:
          type: SelfSigned
      managementState: Managed
      name: knative-serving
    kueue:
      managementState: Managed
    modelmeshserving:
      managementState: Managed
    modelregistry:
      managementState: Managed
    ray:
      managementState: Managed
    #trainingoperator:
    #  managementState: Managed
    #trustyai:
    #  managementState: Managed
    workbenches:
      managementState: Managed
EOF
```

```bash
oc get pods -n redhat-ods-applications
```

Remove the CPU Limits on the notebooks and server so we can better utilize resources.

```bash
cat <<EOF | oc apply -f-
apiVersion: opendatahub.io/v1alpha
kind: OdhDashboardConfig
metadata:
  annotations:
    internal.config.kubernetes.io/previousKinds: OdhDashboardConfig
    internal.config.kubernetes.io/previousNames: odh-dashboard-config
    internal.config.kubernetes.io/previousNamespaces: default
  labels:
    app.kubernetes.io/part-of: rhods-dashboard
    app.opendatahub.io/rhods-dashboard: "true"
  name: odh-dashboard-config
  namespace: redhat-ods-applications
spec:
  dashboardConfig:
    disableAcceleratorProfiles: false
    disableBYONImageStream: false
    disableBiasMetrics: false
    disableClusterManager: false
    disableCustomServingRuntimes: false
    disableDistributedWorkloads: true
    disableISVBadges: false
    disableInfo: false
    disableKServe: false
    disableModelMesh: false
    disableModelServing: false
    disablePerformanceMetrics: false
    disablePipelines: false
    disableProjectSharing: false
    disableProjects: false
    disableSupport: false
    disableTracking: false
    enablement: true
  groupsConfig:
    adminGroups: rhods-admins
    allowedGroups: system:authenticated
  modelServerSizes:
  - name: Small
    resources:
      requests:
        cpu: "1"
        memory: 4Gi
  - name: Medium
    resources:
      requests:
        cpu: "4"
        memory: 8Gi
  - name: Large
    resources:
      requests:
        cpu: "6"
        memory: 16Gi
  notebookController:
    enabled: true
    notebookNamespace: rhods-notebooks
    notebookTolerationSettings:
      enabled: false
      key: NotebooksOnly
    pvcSize: 50Gi
  notebookSizes:
  - name: Small
    resources:
      requests:
        cpu: "1"
        memory: 8Gi
  - name: Medium
    resources:
      requests:
        cpu: "3"
        memory: 24Gi
  - name: Large
    resources:
      requests:
        cpu: "7"
        memory: 56Gi
  - name: X Large
    resources:
      requests:
        cpu: "15"
        memory: 120Gi
  templateDisablement: []
  templateOrder: []
EOF
```

### CPU Limits and Requests

CPU Requests are limiting factor since we only have 16 vCPU's in g6.4xlarge - [stop setting CPU Limits people!](https://home.robusta.dev/blog/stop-using-cpu-limits/)

There are a number of efforts upstream to make resource limits and requests runable via DSC, KNative, Istio etc. For now we can do this once operators are installed:

```bash
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
oc get pods -n knative-serving | grep Pending | awk '{system("oc -n knative-serving delete pod " $1 )}'
```

With these scaled down - we have some headroom - but you will need to scale operators back up for various tasks.

```bash
NODENAME                                   Allocatable CPU  Allocatable MEM  Request CPU  (%)    Limit CPU  (%)     Request MEM  (%)    Limit MEM  (%)
ip-10-0-83-218.us-east-2.compute.internal  15500m           62254244Ki       9981m        (64%)  22450m     (144%)  33674Mi      (55%)  44128Mi    (72%)
```

### Notebooks

Now open RHOAI and Login.

Run the jupyter Notebook - "PyTorch, CUDA v11.8, Python v3.9, PyTorch v2.0, Small, 1 NVIDIA GPU Accelerator".

Make sure you give your notebook plenty of local storage (50-100GB).

You can login as admin or admin2 and work on each notebook separately to see GPU timeslicing in action.

#### llama2
Open the [sno-llama2.ipynb](sno-llama2.ipynb) notebook and have a play. Use the llama2 Swagger UI for trying out chat completions.

#### llama3
Open the [sno-llama3.ipynb](sno-llama3.ipynb) notebook and have a play.

#### granite
Open the [sno-granite.ipynb](sno-granite.ipynb) notebook and have a play.


### Model Serving

Use RHOAI to serve the models with a llama-cpp custom runtime. See [Serving README.md](serving/README.md)
