# SNO on Spot running llama LLM's

A simple method to provision RHOAI on Single Node OpenShift to try out llama LLM's.

We use a g6.4xlarge on aws spot - which comes with a modern Nvidia L4 (20GB), 16 vCPU, 64 GiB RAM.

Running OpenShift 4.15.9 Single Node. Configure Nvidia time slicing to parallel share the GPU.

## Installation

Install OCP.

```bash
export AWS_PROFILE=sno-llama
export AWS_DEFAULT_REGION=us-east-2
export AWS_DEFAULT_ZONES=["us-east-2c"]
export CLUSTER_NAME=sno
export BASE_DOMAIN=sandbox1604.opentlc.com
export PULL_SECRET=$(cat ~/tmp/pull-secret)
export SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
export INSTANCE_TYPE=g6.4xlarge
export ROOT_VOLUME_SIZE=200
export OPENSHIFT_VERSION=4.15.9

mkdir -p ~/tmp/sno-${AWS_PROFILE} && cd ~/tmp/sno-${AWS_PROFILE}

curl -Ls https://raw.githubusercontent.com/eformat/sno-for-100/main/sno-for-100.sh | bash -s -- -d
```

Configure OAuth with htpasswd.

```bash
export CLUSTER_DOMAIN=apps.sno.sandbox1604.opentlc.com
oc login --server=https://api.${CLUSTER_DOMAIN##apps.}:6443 -u kubeadmin -p <PASSWORD>

export ADMIN_PASSWORD=<ADMIN PASSWORD>
htpasswd -bBc /tmp/htpasswd admin ${ADMIN_PASSWORD}

oc adm policy add-cluster-role-to-user cluster-admin admin
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
~/git/acme.sh/acme.sh --issue --dns dns_aws -d ${LE_API} -d *.${LE_WILDCARD} --dnssleep 100 --force --insecure
oc -n openshift-ingress delete secret router-certs
oc -n openshift-ingress create secret tls router-certs --cert=/home/$USER/.acme.sh/${LE_API}/fullchain.cer --key=/home/$USER/.acme.sh/${LE_API}/${LE_API}.key
oc -n openshift-ingress-operator patch ingresscontroller default --patch '{"spec": { "defaultCertificate": { "name": "router-certs"}}}' --type=merge
```

Add 200GB extra Volume. Use ThinLVM from ODS and set as default storage class. 

```bash
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
EOF

oc annotate sc/lvms-vgsno storageclass.kubernetes.io/is-default-class=true
oc annotate sc/gp3-csi storageclass.kubernetes.io/is-default-class-
```

Try out some performance enhancements for your SNO cluster.

- Encapsulating mount namespaces
- Configuring crun as the default container runtime
- 500 pods max

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
cat <<EOF | oc create -f -
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
oc get csv -n nvidia-gpu-operator gpu-operator-certified.v23.9.2 -ojsonpath={.metadata.annotations.alm-examples} | jq .[0] | oc create -n nvidia-gpu-operator -f-
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

oc get events -n nvidia-gpu-operator --sort-by='.lastTimestamp'

oc describe node
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

Configure the RHOAI Data Science Cluster.

```bash
cat <<EOF | oc create -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
  namespace: redhat-ods-operator
  labels:
    app.kubernetes.io/name: datasciencecluster
    app.kubernetes.io/instance: default-dsc
    app.kubernetes.io/part-of: rhods-operator
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/created-by: rhods-operator
spec:
  components:
    codeflare:
      managementState: Managed
    kserve:
      serving:
        ingressGateway:
          certificate:
            type: SelfSigned
        managementState: Managed
        name: knative-serving
      managementState: Managed
    ray:
      managementState: Managed
    kueue:
      managementState: Managed
    workbenches:
      managementState: Managed
    dashboard:
      managementState: Managed
    modelmeshserving:
      managementState: Managed
    datasciencepipelines:
      managementState: Managed
EOF
```

Now open RHOAI and Login.

Run the jupyter Notebook - "PyTorch, CUDA v11.8, Python v3.9, PyTorch v2.0, Small, 1 NVIDIA GPU Accelerator".

Open the [sno-llama2.ipynb](sno-llama2.ipynb) notebook and have a play. Use the llama2 Swagger UI for trying out chat completions.
