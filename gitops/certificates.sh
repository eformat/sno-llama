#!/bin/bash

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color
readonly RUN_DIR=$(pwd)

HOSTED_ZONE=

get_hosted_zone() {
    query='HostedZones[?Name==`'${BASE_DOMAIN}.'`]|[].Id'
    HOSTED_ZONE=$(aws route53 list-hosted-zones --query $query | jq .[])
    echo -e "${GREEN} Hosted Zone ${BASE_DOMAIN}. set to ${HOSTED_ZONE}${NC}"
}

create_caa_route53() {
    echo "🌴 Running create_caa_route53..."

aws route53 change-resource-record-sets \
--region ${AWS_DEFAULT_REGION} \
--hosted-zone-id $(echo ${HOSTED_ZONE} | sed 's/\/hostedzone\///g' | tr -d '"') \
--change-batch file://<(cat << EOF
{
  "Comment": "Upsert CAA",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "caa.${BASE_DOMAIN}.",
        "Type": "CAA",
        "TTL": 300,
        "ResourceRecords": [
            {
              "Value": "0 issuewild \"letsencrypt.org;\""
            }
        ]
      }
    }
  ]
}
EOF
)

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run create_caa_route53 ?${NC}"
      exit 1
    else
      echo "🌴 create_caa_route53 ran OK"
    fi
}

create_aws_secrets() {
    echo "🌴 Running create_aws_secrets..."
    oc -n openshift-config create secret generic aws-secret --from-literal=awsSecretAccessKey=${AWS_SECRET_ACCESS_KEY} 2>&1 | tee /tmp/oc-error-file
    if [ "$?" != 0 ]; then
        if grep -q "already exists" /tmp/oc-error-file; then
            echo -e "${GREEN}Ignoring - secret already exists${NC}"
        else
            echo -e "🚨${RED}Failed - to run create_aws_secrets ?${NC}"
            exit 1
        fi
    fi

    oc -n openshift-ingress create secret generic aws-secret --from-literal=awsSecretAccessKey=${AWS_SECRET_ACCESS_KEY} 2>&1 | tee /tmp/oc-error-file
    if [ "$?" != 0 ]; then
        if grep -q "already exists" /tmp/oc-error-file; then
            echo -e "${GREEN}Ignoring - secret already exists${NC}"
        else
            echo -e "🚨${RED}Failed - to run create_aws_secrets ?${NC}"
            exit 1
        fi
    fi
    echo "🌴 create_aws_secrets ran OK"
}

create_issuers() {
    echo "🌴 Running create_issuers..."

cat <<EOF | oc apply -f-
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-api
  namespace: openshift-config
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "${EMAIL}"
    privateKeySecretRef:
      name: tls-secret
    solvers:
    - dns01:
        route53:
          accessKeyID: ${AWS_ACCESS_KEY_ID}
          hostedZoneID: $(echo ${HOSTED_ZONE} | sed 's/\/hostedzone\///g')
          region: ${AWS_DEFAULT_REGION}
          secretAccessKeySecretRef:
            name: "aws-secret"
            key: "awsSecretAccessKey"
EOF

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run create_issuers ?${NC}"
      exit 1
    fi

cat <<EOF | oc apply -f-
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-ingress
  namespace: openshift-ingress
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "${EMAIL}"
    privateKeySecretRef:
      name: tls-secret
    solvers:
    - dns01:
        route53:
          accessKeyID: ${AWS_ACCESS_KEY_ID}
          hostedZoneID: $(echo ${HOSTED_ZONE} | sed 's/\/hostedzone\///g')
          region: ${AWS_DEFAULT_REGION}
          secretAccessKeySecretRef:
            name: "aws-secret"
            key: "awsSecretAccessKey"
EOF

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run create_issuers ?${NC}"
      exit 1
    else
      echo "🌴 create_issuers ran OK"
    fi
}

create_certificates() {
    echo "🌴 Running create_certificates..."

cat <<EOF | oc apply -f-
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api-cert
  namespace: openshift-config
spec:
  isCA: false
  commonName: "${LE_API}"
  secretName: tls-api
  dnsNames:
  - "${LE_API}" 
  issuerRef:
    name: letsencrypt-api
    kind: Issuer
EOF

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run create_certificates ?${NC}"
      exit 1
    fi

cat <<EOF | oc apply -f-
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: apps-cert
  namespace: openshift-ingress
spec:
  isCA: false
  commonName: "${LE_WILDCARD}"
  secretName: tls-apps
  dnsNames:
  - "${LE_WILDCARD}"
  - "*.${LE_WILDCARD}"
  issuerRef:
    name: letsencrypt-ingress
    kind: Issuer
EOF

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run create_certificates ?${NC}"
      exit 1
    else
      echo "🌴 create_certificates ran OK"
    fi
}

wait_for_api_issuer() {
    oc wait --for=condition=Ready issuer letsencrypt-api -n openshift-config
    local i=0
    until [ "$?" == 0 ]
    do
        echo -e "Wait for issuer letsencrypt-api to be ready."
        ((i=i+1))
        if [ $i -gt 100 ]; then
            echo -e "🚨 Failed - issuer letsencrypt-api never ready?."
            exit 1
        fi
        sleep 5
        oc wait --for=condition=Ready issuer letsencrypt-api -n openshift-config
    done
}

wait_for_ingress_issuer() {
    oc wait --for=condition=Ready issuer letsencrypt-ingress -n openshift-ingress
    local i=0
    until [ "$?" == 0 ]
    do
        echo -e "Wait for issuer letsencrypt-ingress to be ready."
        ((i=i+1))
        if [ $i -gt 100 ]; then
            echo -e "🚨 Failed - issuer letsencrypt-ingress never ready?."
            exit 1
        fi
        sleep 5
        oc wait --for=condition=Ready issuer letsencrypt-ingress -n openshift-ingress
    done
}

wait_for_api_cert() {
    local i=0
    oc wait --for=condition=Ready certificate api-cert -n openshift-config
    until [ "$?" == 0 ]
    do
        echo -e "Wait for certificate api-cert to be ready."
        ((i=i+1))
        if [ $i -gt 100 ]; then
            echo -e "🚨 Failed - certificate api-cert never ready?."
            exit 1
        fi
        sleep 5
        oc wait --for=condition=Ready certificate api-cert -n openshift-config
    done
}

wait_for_ingress_cert() {
    local i=0
    oc wait --for=condition=Ready certificate apps-cert -n openshift-ingress
    until [ "$?" == 0 ]
    do
        echo -e "Wait for certificate apps-cert to be ready."
        ((i=i+1))
        if [ $i -gt 100 ]; then
            echo -e "🚨 Failed - certificate apps-cert never ready?."
            exit 1
        fi
        sleep 5
        oc wait --for=condition=Ready certificate apps-cert -n openshift-ingress
    done
}

patch_api_server() {
    echo "🌴 Running patch_api_server..."

    PATCH='{"spec":{"servingCerts": {"namedCertificates": [{"names": ["'${LE_API}'"], "servingCertificate": {"name": "tls-api"}}]}}}'
    oc patch apiserver cluster --type=merge -p "${PATCH}"

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run patch_api_server ?${NC}"
      exit 1
    else
      echo "🌴 patch_api_server ran OK"
    fi
}

patch_ingress() {
    echo "🌴 Running patch_ingress..."

    oc -n openshift-ingress-operator patch ingresscontroller default --patch '{"spec": { "defaultCertificate": { "name": "tls-apps"}}}' --type=merge

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run patch_ingress ?${NC}"
      exit 1
    else
      echo "🌴 patch_ingress ran OK"
    fi
}

all() {
    echo "🌴 BASE_DOMAIN set to $BASE_DOMAIN"

    create_aws_secrets
    get_hosted_zone
    create_caa_route53

    create_issuers
    wait_for_api_issuer
    wait_for_ingress_issuer

    create_certificates
    wait_for_api_cert
    wait_for_ingress_cert

    patch_api_server
    patch_ingress
}

progress() {
    cat <<EOF 2>&1
🌻 Track progress using: 🌻

  watch oc get co
EOF
}

# Check for EnvVars
[ -z "$EMAIL" ] && echo "🕱 Error: must supply EMAIL in env or cli" && exit 1
[ -z "$BASE_DOMAIN" ] && echo "🕱 Error: must supply BASE_DOMAIN in env or cli" && exit 1
[ -z "$AWS_ACCESS_KEY_ID" ] && echo "🕱 Error: AWS_ACCESS_KEY_ID not set in env" && exit 1
[ -z "$AWS_SECRET_ACCESS_KEY" ] && echo "🕱 Error: AWS_SECRET_ACCESS_KEY not set in env" && exit 1
[ -z "$AWS_DEFAULT_REGION" ] && echo "🕱 Error: AWS_DEFAULT_REGION not set in env" && exit

# set these
LE_API=$(oc whoami --show-server | cut -f 2 -d ':' | cut -f 3 -d '/' | sed 's/-api././')
LE_WILDCARD=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}')
[ -z "$LE_API" ] && echo "🕱 Error: LE_API could not set" && exit 1
[ -z "$LE_WILDCARD" ] && echo "🕱 Error: LE_WILDCARD could not set" && exit

all

progress
echo -e "\n🌻${GREEN}Certificates configured OK.${NC}🌻\n"
exit 0