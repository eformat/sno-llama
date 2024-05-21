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

## Install Everything Else

Bootstrap ArgoCD operator and everything using gitops (GPU, Cluster PerfEnhancements, CertManager, GPU Setup, LVM+Noobaa/S3 Storage, RHOAI). Your SNO will reboot for MachineConfig updates.

```bash
./gitops/install.sh -d
```

Create Users using htpasswd. Delete's the kubeadmin user.

```bash
./gitops/users.sh
```

Install Let's Encrypt certificates for api, apps - using CertManager and Route53.

```bash
./gitops/certificates.sh
```

Scale the RHOAI Platform down a bit so we free up some cpu.

```bash
./gitops/scale-resources.sh
```

The [manual instructions](MANUAL_INSTALL.md) are still here if you want to run them.

## Model Notebooks

Now open RHOAI and Login.

Run the jupyter Notebook - "PyTorch, CUDA v11.8, Python v3.9, PyTorch v2.0, Small, 1 NVIDIA GPU Accelerator".

Make sure you give your notebook plenty of local storage (50-100GB).

You can login as admin or admin2 and work on each notebook separately to see GPU timeslicing in action.

#### Llama2
Meta's [llama-2 model.](https://llama.meta.com/llama2)

Open the [sno-llama2.ipynb](sno-llama2.ipynb) notebook and have a play.

#### Llama3
Meta's [llama-3 model.](https://llama.meta.com/llama3)

Open the [sno-llama3.ipynb](sno-llama3.ipynb) notebook and have a play.

#### Granite
InstructLab's [opensource granite model.](https://huggingface.co/instructlab)

Open the [sno-granite.ipynb](sno-granite.ipynb) notebook and have a play.

#### Code-Llama
Deploy your own [IDE python coding assistant.](continue/README.md)

Open the [sno-code-llama.ipynb](sno-code-llama.ipynb) notebook and have a play.

#### Prompt Caching
How can we start to remeber previous chat contexts using llama.cpp

Open the [sno-prompt-cache.ipynb](sno-prompt-cache.ipynb) notebook and have a play.

#### Instructlab

Use RHOAI try out [instructlab](https://github.com/instructlab/instructlab) using a notebook image. See [Instructlab README.md](instructlab/README.md)

Open the [sno-instructlab.ipynb](sno-instructlab.ipynb) notebook and have a play.

### Model Serving

Use RHOAI to serve the models with a llama-cpp custom runtime. See [Serving README.md](serving/README.md)

## Delete SNO instance

If you no longer need your instance, to remove all related aws objects just run **inside your `$RUNDIR`**.

```bash
openshift-install destroy cluster --dir=cluster
```
