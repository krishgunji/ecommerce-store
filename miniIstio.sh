#!/bin/bash
set -e

# Variables
BACKEND_IMAGE="krishangunjyal/ecommerce-backend:latest"
FRONTEND_IMAGE="krishangunjyal/ecommerce-frontend:latest"
NAMESPACE="helix"

command_exists() { command -v "$1" >/dev/null 2>&1; }

echo "========== MINIKUBE & ISTIO SETUP =========="

# Check minikube installation
if ! command_exists minikube; then
  echo "Minikube not found. Installing minikube..."
  curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  install minikube-linux-amd64 /usr/local/bin/minikube
else
  echo "Minikube is already installed."
fi

# Start Minikube with 4GB RAM and 2 CPUs if not running
if ! minikube status >/dev/null 2>&1; then
  echo "Starting Minikube cluster with 4GB RAM and 2 CPUs..."
  minikube start --memory=4096 --cpus=2 --driver=docker
else
  echo "Minikube cluster already running."
fi

# Enable Istio addon with minimal profile
echo "Enabling Istio addon in Minikube..."
minikube addons enable istio

# Wait for Istio pods to be ready
echo "Waiting for Istio pods to be ready..."
kubectl -n istio-system wait --for=condition=Ready pod -l app=istiod --timeout=3m
kubectl -n istio-system wait --for=condition=Ready pod -l app=istio-ingressgateway --timeout=3m

# Create namespace if missing
if ! kubectl get namespace $NAMESPACE >/dev/null 2>&1; then
  echo "Creating namespace $NAMESPACE"
  kubectl create namespace $NAMESPACE
fi

# Disable automatic sidecar injection for stability
echo "Disabling Istio sidecar injection on $NAMESPACE namespace..."
kubectl label namespace $NAMESPACE istio-injection- --overwrite

echo "========== DEPLOYING MONGODB WITH MINIMAL RESOURCES =========="

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
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            cpu: 100m
            memory: 256Mi
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

echo "========== DEPLOYING BACKEND AND FRONTEND APPS =========="

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
        resources:
          requests:
            cpu: 10m
            memory: 64Mi
          limits:
            cpu: 50m
            memory: 128Mi
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
        resources:
          requests:
            cpu: 10m
            memory: 64Mi
          limits:
            cpu: 50m
            memory: 128Mi
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
EOF

echo "========== ISTIO GATEWAY SETUP =========="

cat <<EOF | kubectl apply -f -
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

# Get ingressgateway NodePort
NODE_PORT=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
NODE_IP=$(minikube ip)

echo "=================================================="
echo "Access Frontend: http://$NODE_IP:$NODE_PORT/"
echo "Access Backend API: http://$NODE_IP:$NODE_PORT/api/hello"
echo "MongoDB URI: mongodb://mongo.$NAMESPACE.svc.cluster.local:27017/ecommerceDB"
echo "Istio testing setup complete."
