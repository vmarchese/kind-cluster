#!/usr/bin/env bash
    
set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT


script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
    
#
# HELP
#
usage() {
      cat <<EOF
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-a address] [-s] [-d domain] [-n name] [-w workers] [-l logfile] [-j] [-o] [-p] [-g]
    
    Creates a kind cluster with optional observability stack.
    
    Available options:
    
    -h, --help               Print this help and exit
    -a, --address            Cluster address (defaults to "0.0.0.0")
    -s, --skip-create        Skip cluster creation
    -d, --domain             Cluster domain (defaults to "dev.localhost")
    -i, --issuer             Cluster issuer (defaults to "https://kubernetes.default.svc.cluster.local")
    -n, --name               Cluster name (defaults to "kind")
    -w, --workers            Number of workers (defaults to 1, , must be >=1 )
    -r, --registry_hostname  Registry hostname (default: registry.localhost)
    -l, --log-file           Log file (default to tmp)
    -j, --jaeger             Install Jaeger
    -o, --otel               Install OpenTelemetry collector
    -p, --prometheus         Install Prometheus
    -g, --grafana            Install Grafana
    -v, --verbose            Print script debug info
    -V, --kind-verbose       Sets kind log verbosity
EOF
  exit
}


    
cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}


setup_colors() {
   if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
     NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'  NC='\033[0m' 
     CHECK="${GREEN}\u2713${NC}"
   else
        NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW='' NC=''
        CHECK='ok'
   fi
}
    
msg() {
  echo >&2 -e "${1-}"
}
    
die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}



#
# Parse Parameters
#
parse_params() {
  # default values of variables set from params
  jaeger=0
  prometheus=0
  grafana=0
  otel=0
  skipcreate=0
  cluster_name='kind'
  cluster_address='0.0.0.0'
  cluster_issuer='https://kubernetes.default.svc.cluster.local'
  cluster_domain='dev.localhost'
  workers=1
  log_file="/tmp/createcluster-$$.log"
  registry_hostname='registry.localhost'
  set +e
  kubectl=$(which kubectl)
  [[ -z "${kubectl-}" ]] && die "Missing kubectl, please install it from https://kubernetes.io/docs/tasks/tools/"
  set -e
  kind_verbosity=0

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    -V | --kind-verbose) kind_verbosity=100 ;;
    --no-color) NO_COLOR=1 ;;
    -j | --jaeger) jaeger=1 ;;
    -p | --prometheus) prometheus=1 ;;
    -g | --grafana) grafana=1 ;;
    -o | --otel) otel=1 ;;
    -s | --skip-create) skipcreate=1 ;;
    -l | --log-file) 
      log_file="${2-}"
      shift
      ;;    
    -w | --workers) 
      workers="${2-}"
      shift
      ;;
    -a | --address) 
      cluster_address="${2-}"
      shift
      ;;
    -i | --issuer) 
      cluster_issuer="${2-}"
      shift
      ;;
    -n | --name) 
      cluster_name="${2-}"
      shift
      ;;
    -d | --domain) 
      cluster_domain="${2-}"
      shift
      ;;
    -r | --registry-hostname) 
      registry_hostname="${2-}"
      shift
      ;; 
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ ${skipcreate} == "0" ]] && [[ -z "${cluster_address-}" ]] && die "Missing required parameter: address"
  [[ -z "${cluster_domain-}" ]] && die "Missing required parameter: domain"
  if [[ ${workers} < 1 ]]; then
    echo "workers number must be >= 1"
    exit 1
  fi  


  return 0
}

#
# Create Cluster
#
create_cluster(){

  echo -en "${NC}Creating Cluster${NC} "

clustername=${cluster_name}
#multipassip=$(multipass list | grep mpdocker | awk '{print $3;}')
cluster_address=${cluster_address}

# create registry container unless it already exists
reg_name='kind-registry'
reg_port='5000'
running="$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)"
if [ "${running}" != 'true' ]; then
  docker run \
    -d --restart=always -p "${cluster_address}:${reg_port}:5000" --name "${reg_name}" \
    registry:2 >> ${log_file} 2>&1
fi

worker_list=""
if [[ ${workers} != "0" ]]; then
worker_list=$(for i in $(seq 1 ${workers}); do echo "- role: worker"; done)
fi

# create a cluster with the local registry enabled in containerd
{
cat <<EOF | kind create cluster -v ${kind_verbosity} --config=-
kind: Cluster
name: ${clustername}
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  ipFamily: ipv4
  apiServerAddress: ${cluster_address}
  apiServerPort: 6443
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${reg_name}:${reg_port}"]
    endpoint = ["http://${reg_name}:5000"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."${reg_name}:${reg_port}.tls"]
    insecure_skip_verify = true
    cert_file = ""
    key_file = ""
    ca_file = ""
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${reg_port}"]
    endpoint = ["http://${reg_name}:5000"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."localhost:${reg_port}.tls"]
    insecure_skip_verify = true
    cert_file = ""
    key_file = ""
    ca_file = ""
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${registry_hostname}:${reg_port}"]
    endpoint = ["http://${reg_name}:5000"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."${registry_hostname}:${reg_port}.tls"]
    insecure_skip_verify = true
    cert_file = ""
    key_file = ""
    ca_file = ""
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  - |
    kind: ClusterConfiguration
    apiServer:
        extraArgs:
          service-account-issuer: ${cluster_issuer}
          service-account-jwks-uri: ${cluster_issuer}/openid/v1/jwks
          service-account-signing-key-file: /etc/kubernetes/pki/sa.key
          service-account-key-file: /etc/kubernetes/pki/sa.pub
  extraPortMappings:
  - containerPort: 80
    hostPort: 8080
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP  
${worker_list}
EOF
} >> ${log_file} 2>&1

# connect the registry to the cluster network
# (the network may already be connected)
docker network connect "kind" "${reg_name}"  >> ${log_file} 2>&1 || true

# Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
{
cat <<EOF | ${kubectl} apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
}  >> ${log_file}  2>&1

 echo -e "${CHECK}"
}

#
# Install ingress controller
#
install_ingress(){
 echo -en "${NC}Installing NGINX Ingress${NC} "
 ${kubectl} apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml >> ${log_file} 2>&1
 ${kubectl} wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s >> ${log_file} 2>&1
 echo -e "${CHECK}"

}

#
# Create observability namespace
#
create_observability_namespace(){

  ${kubectl} create namespace observability --dry-run=client -o yaml | ${kubectl} apply -f - >> ${log_file} 2>&1

}

#
# Install Certificate Manager
#
install_cert_manager (){
 echo -en "${NC}Installing Certificate Manager${NC} "
 ${kubectl} apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.6.3/cert-manager.yaml >> ${log_file} 2>&1

 ${kubectl} wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s  >> ${log_file} 2>&1

 ${kubectl} wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=webhook \
  --timeout=120s   >> ${log_file} 2>&1
 echo -e "${CHECK}"
}

#
# Install Jaeger
#
install_jaeger(){
 echo -en "${NC}Installing Jaeger Operator${NC} "
 ${kubectl} apply -f https://github.com/jaegertracing/jaeger-operator/releases/download/v1.40.0/jaeger-operator.yaml -n observability >> ${log_file} 2>&1

 ${kubectl} wait --namespace observability \
  --for=condition=ready pod \
  --selector=name=jaeger-operator \
  --timeout=120s  >> ${log_file} 2>&1

 sleep 2 # must wait on service

{
cat <<EOF | ${kubectl} apply  -n observability -f -
apiVersion: jaegertracing.io/v1
kind: Jaeger
metadata:
  name: simplest
spec:
  ingress:
    enabled: false
EOF
} >> ${log_file}  2>&1

sleep 2
 ${kubectl} wait --namespace observability \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=simplest \
  --timeout=120s >> ${log_file} 2>&1


{
cat <<EOF | ${kubectl} apply  -n observability -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jaeger
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /\$1
spec:
  rules:
  - host: jaeger.${cluster_domain}
    http:
      paths:
      - pathType: Prefix
        path: /
        backend:
          service:
            name: simplest-query
            port:
             number: 16686 
EOF
} >> ${log_file}  2>&1

 echo -e "${CHECK}"
}

#
# Install Prometheus
#
install_prometheus(){
  echo -en "${NC}Installing Prometheus${NC} "
  if ! helm ls -n observability | grep -q prometheus; then
    echo -en "...adding prometheus community chart" >> ${log_file} 2>&1
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >> ${log_file} 2>&1

    echo -en "...installing prometheus" >> ${log_file} 2>&1
    helm install prometheus prometheus-community/prometheus -n observability >> ${log_file} 2>&1

    echo -en "...waiting for prometheus" >> ${log_file} 2>&1
    ${kubectl} wait --namespace observability \
      --for=condition=ready pod \
      --selector=app.kubernetes.io/instance=prometheus \
      --timeout=300s >> ${log_file} 2>&1  
  else
    echo -en "...prometheus already installed" >> ${log_file} 2>&1
  fi
  echo -e "${CHECK}"
}

#
# Install Grafana
#
install_grafana(){

  echo -en "${NC}Installing Grafana${NC} "
{
cat <<EOF | ${kubectl} apply  -n observability -f -
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: grafana
  name: grafana
spec:
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      securityContext:
        fsGroup: 472
        supplementalGroups:
          - 0
      containers:
        - name: grafana
          image: grafana/grafana:9.1.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 3000
              name: http-grafana
              protocol: TCP
          readinessProbe:
            failureThreshold: 3
            httpGet:
              path: /robots.txt
              port: 3000
              scheme: HTTP
            initialDelaySeconds: 10
            periodSeconds: 30
            successThreshold: 1
            timeoutSeconds: 2
          livenessProbe:
            failureThreshold: 3
            initialDelaySeconds: 30
            periodSeconds: 10
            successThreshold: 1
            tcpSocket:
              port: 3000
            timeoutSeconds: 1
          resources:
            requests:
              cpu: 250m
              memory: 750Mi
          volumeMounts:
            - mountPath: /var/lib/grafana
              name: grafana-pv
      volumes:
        - name: grafana-pv
          persistentVolumeClaim:
            claimName: grafana-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
spec:
  ports:
    - port: 3000
      protocol: TCP
      targetPort: http-grafana
  selector:
    app: grafana
  sessionAffinity: None
  type: ClusterIP
EOF
} >> ${log_file}  2>&1


 ${kubectl} wait --namespace observability \
  --for=condition=ready pod \
  --selector=app=grafana \
  --timeout=120s >> ${log_file} 2>&1

{
cat <<EOF | ${kubectl} apply  -n observability -f - 
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /\$1
spec:
  rules:
  - host: grafana.${cluster_domain}
    http:
      paths:
      - pathType: Prefix
        path: /(.*)
        backend:
          service:
            name: grafana
            port:
             number: 3000 
EOF
} >> ${log_file}  2>&1

        
 echo -e "${CHECK}"
}

#
# Install OTEL
#
install_otel(){

[[  ${prometheus} = "0" ]] && install_prometheus

 echo -en "${NC}Installing OpenTelemetry Collector${NC} "

  if ! helm ls -n observability | grep -q opentelemetry-operator; then
    echo -en "...adding opentelemetry chart" >> ${log_file} 2>&1
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >> ${log_file} 2>&1

    echo -en "...installing opentelemetry" >> ${log_file} 2>&1
    helm install opentelemetry-operator open-telemetry/opentelemetry-operator -n observability \
         --set "manager.collectorImage.repository=otel/opentelemetry-collector-k8s"    >> ${log_file} 2>&1


    ${kubectl} wait --namespace observability\
      --for=condition=ready pod \
      --selector=app.kubernetes.io/name=opentelemetry-operator \
      --timeout=240s >> ${log_file} 2>&1
  else
    echo -en "...opentelemetry already installed" >> ${log_file} 2>&1
  fi      


{
cat <<EOF | ${kubectl} apply  -n observability -f - 
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: simplest
spec:
  mode: deployment 
  config: 
    receivers:
      otlp:
        protocols:
          grpc:
          http:

    processors:
      batch:

    exporters:
      logging:
        loglevel: debug

      otlp/jaeger:
        endpoint: "simplest-collector.observability.svc.cluster.local:4317"
        tls:
          insecure: true

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [logging,otlp/jaeger]
EOF
} >> ${log_file}  2>&1


 echo -e "${CHECK}"
}

  jaeger=0
  prometheus=0
  grafana=0
  otel=0
  skipcreate=0
  cluster_name='kind'
  cluster_address=''
  cluster_domain=''
  workers=1
  log_file="/tmp/createcluster-$$.log"


dump_config(){
 echo -e "${GREEN}Creating Kind Cluster:${NC} ${cluster_name}"
 echo -e " ${GREEN}skip creation:${NC}        ${skipcreate}"
 echo -e " ${GREEN}workers:${NC}              ${workers}"
 echo -e " ${GREEN}address:${NC}              ${cluster_address}"
 echo -e " ${GREEN}domain:${NC}               ${cluster_domain}"
 echo -e " ${GREEN}issuer:${NC}               ${cluster_issuer}"
 echo -e " ${GREEN}registry_hostname:${NC}    ${registry_hostname}"
 echo -e " ${GREEN}jaeger:${NC}               ${jaeger}"
 echo -e " ${GREEN}prometheus:${NC}           ${prometheus}"
 echo -e " ${GREEN}grafana:${NC}              ${grafana}"
 echo -e " ${GREEN}otel:${NC}                 ${otel}"
 echo -e " ${GREEN}log_file:${NC}             ${log_file}"
}


parse_params "$@"
setup_colors

dump_config
echo "" >> ${log_file}

if [[ ${skipcreate} = "0" ]]; then
create_cluster
install_ingress
fi

if [[ ${jaeger} = "1" ]] ||  [[ ${prometheus} = "1" ]] || [[ ${grafana} = "1" ]] || [[ ${otel} = "1" ]]; then
 install_cert_manager

 create_observability_namespace

 [[  ${jaeger} = "1" ]] && install_jaeger
 [[  ${prometheus} = "1" ]] && install_prometheus
 [[  ${grafana} = "1" ]] && install_grafana
 [[  ${otel} = "1" ]] && install_otel

fi

if [[ ${jaeger} = "1" ]]; then
 echo -e "${YELLOW}Jaeger Query is reachable at http://jaeger.${cluster_domain}${NC}"
fi

if [[ ${grafana} = "1" ]]; then
 echo -e "${YELLOW}Grafana UI is reachable at http://grafana.${cluster_domain}${NC}"
 echo -e "   ${GREEN}user/password:${NC} admin/admin"
fi
