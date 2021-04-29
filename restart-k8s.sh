#! /bin/bash

set -e

echo " * Restarting containerd"
systemctl start containerd
echo

echo " * Waiting for k8s node to become available..."
while ! kubectl get nodes; do
  echo "...still waiting"
  sleep 5;
done
echo

echo " * Allowing node to schedule"
kubectl uncordon localhost.localdomain
echo

echo " * Waiting for kotsadm to stand up (5 minute timeout...)"
kubectl wait --for=condition=Ready pod -l app=kotsadm --timeout=300s
echo

echo "Please reset the kotsadm password."
kubectl kots reset-password default
