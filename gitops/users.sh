#!/bin/bash

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color
readonly RUN_DIR=$(pwd)

export NO_ADMINS=${NO_ADMINS:-2}

create_htpasswd() {
    echo "🌴 Running create_htpasswd..."
    for x in `seq 1 ${NO_ADMINS}`; do
        [ $x == 1 ] && htpasswd -bBc /tmp/htpasswd admin ${ADMIN_PASSWORD}
        [ $x -gt 1 ] && htpasswd -bB /tmp/htpasswd admin$x ${ADMIN_PASSWORD}
    done
    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run create_htpasswd ?${NC}"
      exit 1
    else
      echo "🌴 create_htpasswd ran OK"
    fi
}

add_cluster_admins() {
    echo "🌴 Running add_cluster_admins..."
    for x in `seq 1 ${NO_ADMINS}`; do
        [ $x == 1 ] && oc adm policy add-cluster-role-to-user cluster-admin admin
        [ $x -gt 1 ] && oc adm policy add-cluster-role-to-user cluster-admin admin$x
    done
    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run add_cluster_admins ?${NC}"
      exit 1
    else
      echo "🌴 add_cluster_admins ran OK"
    fi
}

configure_oauth() {
    echo "🌴 Running configure_oauth..."
    oc delete secret htpasswdidp-secret -n openshift-config
    oc create secret generic htpasswdidp-secret -n openshift-config --from-file=/tmp/htpasswd

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to create secret, configure_oauth ?${NC}"
      exit 1
    fi

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
    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to create oauth, configure_oauth ?${NC}"
      exit 1
    fi

    oc delete secret kubeadmin -n kube-system 2>&1 | tee /tmp/oc-error-file
    if [ "$?" != 0 ]; then
        if grep -q "not found" /tmp/oc-error-file; then
            echo -e "${GREEN}Ignoring - kubeadmin does not exist${NC}"
        else
            echo -e "🚨${RED}Failed - to delete kubeadmin, configure_oauth ?${NC}"
            exit 1
        fi
    fi
    echo "🌴 configure_oauth ran OK"
}

all() {
    echo "🌴 BASE_DOMAIN set to $BASE_DOMAIN"
    echo "🌴 NO_ADMINS set to $NO_ADMINS"

    create_htpasswd
    add_cluster_admins
    configure_oauth
}

# Check for EnvVars
[ -z "$BASE_DOMAIN" ] && echo "🕱 Error: must supply BASE_DOMAIN in env or cli" && exit 1
[ -z "$ADMIN_PASSWORD" ] && read -s -p "ADMIN_PASSWORD: " ADMIN_PASSWORD

CLUSTER_DOMAIN=apps.${BASE_DOMAIN}

all

echo -e "\n🌻${GREEN}Users configured OK.${NC}🌻\n"
exit 0