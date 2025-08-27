#!/bin/bash
set -e

# Variables
BACKEND_IMAGE="krishangunjyal/ecommerce-backend:latest"
FRONTEND_IMAGE="krishangunjyal/ecommerce-frontend:latest"
NAMESPACE="helix"
KUBECTL_BIN="kubectl"
KIND_BIN="kind"

command_exists() { command -v "$1" >/dev/null 2>&1; }

echo "========== ENVIRONMENT & KUBERNETES SETUP =========="

# Check if kubectl is installed
if ! command_exists $KUBECTL_BIN; then
  echo "kubectl not found. Installing kubectl..."
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
else
  echo "kubectl is already installed."
fi

# Check if Kubernetes cluster is reachable
if ! kubectl version --short >/dev/null 2>&1; then
  echo "No accessible Kubernetes cluster found."
  # Check if kind is installed
  if ! command_exists $KIND_BIN; then
    echo "kind not found. Installing kind..."
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
    chmod +x ./kind
    mv ./kind /usr/local/bin/kind
  else
    echo "kind is already installed."
  fi
  # Create kind cluster
  echo "Creating local Kubernetes cluster with kind..."
  kind create cluster --name ecommerce-cluster
else
  echo "Kubernetes cluster is accessible."
fi

# Create namespace if not exists
if ! kubectl get namespace $NAMESPACE >/dev/null 2>&1; then
  echo "Creating namespace $NAMESPACE"
  kubectl create namespace $NAMESPACE
fi

echo "========== DEPLOYING APPS WITH ISTIO AND MONGODB =========="

# Istioctl install check
if ! command_exists istioctl; then
  echo "Installing Istio CLI..."
  curl -L https://istio.io/downloadIstio | sh -
  cd istio-*
  export PATH="$PWD/bin:$PATH"
  cd /
else
  echo "Istio CLI already installed."
fi

# Istio install (demo profile, idempotent)
echo "Installing Istio control plane..."
istioctl install --set profile=demo -y

# Patch istio ingressgateway to NodePort for kind/local access
echo "Setting istio-ingressgateway Service to NodePort..."
kubectl -n istio-system patch svc istio-ingressgateway -p '{"spec": {"type": "NodePort"}}'

# Enable automatic sidecar injection on namespace
kubectl label namespace $NAMESPACE istio-injection=enabled --overwrite

# Deploy MongoDB StatefulSet and Service
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: mongo
  namespace: $NAMESPACE
spec:
  ports:
  - port: 27017
    targetPort: 27017
  selector:
    app: mongo
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongo
  namespace: $NAMESPACE
spec:
  serviceName: "mongo"
  replicas: 1
  selector:
    matchLabels:
      app: mongo
  template:
    metadata:
      labels:
        app: mongo
    spec:
      containers:
      - name: mongo
        image: mongo:6.0
        ports:
        - containerPort: 27017
        volumeMounts:
        - name: mongo-persistent-storage
          mountPath: /data/db
  volumeClaimTemplates:
  - metadata:
      name: mongo-persistent-storage
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
EOF

# Deploy ecommerce backend and frontend apps and Istio routing
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ecommerce-backend
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ecommerce-backend
  template:
    metadata:
      labels:
        app: ecommerce-backend
    spec:
      containers:
      - name: ecommerce-backend
        image: $BACKEND_IMAGE
        ports:
        - containerPort: 5000
        env:
        - name: MONGO_URI
          value: "mongodb://mongo.$NAMESPACE.svc.cluster.local:27017/ecommerceDB"
---
apiVersion: v1
kind: Service
metadata:
  name: ecommerce-backend
  namespace: $NAMESPACE
spec:
  selector:
    app: ecommerce-backend
  ports:
  - protocol: TCP
    port: 80
    targetPort: 5000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ecommerce-frontend
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ecommerce-frontend
  template:
    metadata:
      labels:
        app: ecommerce-frontend
    spec:
      containers:
      - name: ecommerce-frontend
        image: $FRONTEND_IMAGE
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: ecommerce-frontend
  namespace: $NAMESPACE
spec:
  selector:
    app: ecommerce-frontend
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
---
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: ecommerce-gateway
  namespace: $NAMESPACE
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ecommerce-virtualservice
  namespace: $NAMESPACE
spec:
  hosts:
  - "*"
  gateways:
  - ecommerce-gateway
  http:
  - match:
    - uri:
        prefix: "/api"
    route:
    - destination:
        host: ecommerce-backend.$NAMESPACE.svc.cluster.local
        port:
          number: 80
  - route:
    - destination:
        host: ecommerce-frontend.$NAMESPACE.svc.cluster.local
        port:
          number: 80
EOF

# Fetch node IP and NodePort to access services
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_PORT=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')

echo "=========================================================="
echo "Access your frontend app at: http://$NODE_IP:$NODE_PORT/"
echo "Access backend API at:       http://$NODE_IP:$NODE_PORT/api/hello"
echo "MongoDB service URI:        mongodb://mongo.$NAMESPACE.svc.cluster.local:27017/ecommerceDB"
echo "Deployment completed successfully."
