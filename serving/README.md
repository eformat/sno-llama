## Kserve

Serve our models using custom llama-cpp serving runtime.

### Copy Models to S3 Noobaa

Once you have run the notebooks, copy the downloaded models into S3.

```bash
pip install awscli
```

```bash
export NOOBAA_ACCESS_KEY=$(oc get secret noobaa-admin -n openshift-storage -o json | jq -r '.data.AWS_ACCESS_KEY_ID|@base64d')
export NOOBAA_SECRET_KEY=$(oc get secret noobaa-admin -n openshift-storage -o json | jq -r '.data.AWS_SECRET_ACCESS_KEY|@base64d')
alias s3='AWS_ACCESS_KEY_ID=$NOOBAA_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$NOOBAA_SECRET_KEY aws --endpoint https://s3-openshift-storage.apps.sno.sandbox.opentlc.com:443 s3'
s3 ls
```

```bash
s3 mb s3://models
s3 cp granite-7b-lab-Q4_K_M.gguf s3://models/granite-7b-lab-Q4_K_M.gguf
s3 cp llama-2-7b-chat.Q4_K_M.gguf s3://models/llama-2-7b-chat.Q4_K_M.gguf
s3 cp Meta-Llama-3-8B-Instruct-Q8_0.gguf s3://models/Meta-Llama-3-8B-Instruct-Q8_0.gguf
```

### Deploy Serving Runtime Template in RHOAI

In RHOAI - Browse to Serving Runtimes > Add Serving Runtime > Start from scratch

Add in LLamaCPP template:

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
labels:
  opendatahub.io/dashboard: "true"
metadata:
  annotations:
    openshift.io/display-name: LLamaCPP
    opendatahub.io/recommended-accelerators: '["nvidia.com/gpu"]'
  name: llamacpp
spec:
  builtInAdapter:
    modelLoadingTimeoutMillis: 90000
  containers:
    - image: llama-serving:latest
      name: kserve-container
      env:
      - name: MODELNAME
        value: "granite-7b-lab-Q4_K_M.gguf"
      - name: MODELLOCATION
        value: /mnt/models
      - name: CHAT_FORMAT
        value: ""
      volumeMounts:
        - name: shm
          mountPath: /dev/shm
      ports:
        - containerPort: 8000
          protocol: TCP
      volumes:
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 1Gi
  multiModel: false
  supportedModelFormats:
    - autoSelect: true
      name: gguf
```

### Deploy Serving Runtime Instances

Create a RHOAI Data Science project called `llama-serving`.

Create S3 secret:

```bash
oc apply -f - <<EOF
kind: Secret
apiVersion: v1
metadata:
  name: connection-noobaa
  namespace: llama-serving
  labels:
    opendatahub.io/dashboard: 'true'
    opendatahub.io/managed: 'true'
  annotations:
    opendatahub.io/connection-type: s3
    openshift.io/display-name: noobaa
stringData:
  AWS_ACCESS_KEY_ID: <NOOBAA_ACCESS_KEY>
  AWS_DEFAULT_REGION: us-east-1
  AWS_S3_BUCKET: models
  AWS_S3_ENDPOINT: https://s3-openshift-storage.apps.sno.sandbox.opentlc.com:443
  AWS_SECRET_ACCESS_KEY: <NOOBAA_SECRET_KEY>
type: Opaque
EOF
```

Create ServingRuntime and InferenceService instances.

```bash
oc apply -f serving-granite.yaml
oc apply -f serving-llama2.yaml
```

### Query

Browse to the llama-cpp docs SwaggerUI.

Or call from CLI.

```bash
# Choose an model serving endpoint to query
HOST=https://sno-granite-llama-serving.apps.sno.sandbox.opentlc.com
HOST=https://sno-llama2-llama-serving.apps.sno.sandbox.opentlc.com

curl -k -X GET $HOST/v1/models -H 'accept: application/json'

curl -s -k -X 'POST' \
  "$HOST/v1/completions" \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "prompt": "\n\n### Q:\nWhat is the capital of France?\n\n### A:\n",
  "stop": [
    "\n",
    "###"
  ]
}' | jq .

curl -s -k -X 'POST' \
  "$HOST/v1/completions" \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "prompt": "\n\n### Q:\nWho is consistently the best rugby team in the world?\n\n### A:\n",
  "max_tokens": "100",
  "stop": [
    "\n",
    "###"
  ]
}' | jq .
```
