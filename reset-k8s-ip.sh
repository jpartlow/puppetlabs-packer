#! /bin/bash

set -e

# This only needs to be run if the checked out vm has ended up with an IP address
# that no longer matches the one it had when k8s was configured.

force=$1


current_ip=$(ip -br address | grep '^ens' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')

replicated_kubeadm_conf=/opt/replicated/kubeadm.conf
configured_k8s_ip=$(grep node-ip: "${replicated_kubeadm_conf}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
configured_k8s_service_cidr=$(grep serviceSubnet: "${replicated_kubeadm_conf}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+')

echo "Host IP:"
ip -br address | grep ens
echo

echo "Routes:"
ip route
echo

echo "The current host ip is: ${current_ip}"
echo "And based on ${replicated_kubeadm_conf}, the vm was configured with: ${configured_k8s_ip} and a service cidr of ${configured_k8s_service_cidr}"

if [ "${current_ip}" = "${configured_k8s_ip}" ] && [ "${force}" != 'force' ]; then
  echo "So there's nothing to reset."
else
  echo "Need to reset the k8s configuration."

  ####################
  # From:
  # https://github.com/kubernetes/kubeadm/issues/338#issuecomment-460935394

  echo " * Stopping kubelet and containerd"
  systemctl stop kubelet containerd

  echo " * Backing up old kubernetes data"
  if [ -d /etc/kubernetes ]; then
    mv -n /etc/kubernetes /etc/kubernetes-backup
  fi
  if [ -d /var/lib/kubelet ]; then
    mv -n /var/lib/kubelet /var/lib/kubelet-backup
  fi
  if [ ! -e "${replicated_kubeadm_conf}.bak" ]; then
    cp "${replicated_kubeadm_conf}" "${replicated_kubeadm_conf}.bak"
  fi

  echo " * Restoring certificates"
  mkdir -p /etc/kubernetes
  cp -r /etc/kubernetes-backup/pki /etc/kubernetes
  rm /etc/kubernetes/pki/{apiserver.*,etcd/peer.*}

  echo " * Restarting containerd"
  systemctl start containerd

  echo " * Reinitializing k8s primary with data in etcd and original replicated options updated to ${current_ip}"
  sed -ie "s/${configured_k8s_ip}/${current_ip}/" "${replicated_kubeadm_conf}"
  # Cribbed from Replicated ~/install.sh...
  # find a network for the services, preferring start at 10.96.0.0
  if servicenet=$(~/bin/subnet --subnet-alloc-range "10.96.0.0/16" --cidr-range "22" --exclude-subnet "${current_ip}/16"); then
      echo "Found service network: $servicenet"
      new_service_cidr="$servicenet"
      sed -ie "s|${configured_k8s_service_cidr}|${new_service_cidr}|" "${replicated_kubeadm_conf}"
  else
    echo "Failed to find an acceptable new service cidr for kubeadm.conf"
    exit 1
  fi
  kubeadm init --ignore-preflight-errors=all --config "${replicated_kubeadm_conf}"
  echo

  echo " * Updating kubectl config"
  cp /etc/kubernetes/admin.conf ~/.kube/config

  echo " * Waiting for new node and deleting old node"
  kubectl get nodes --sort-by=.metadata.creationTimestamp
  kubectl wait --for condition=ready "node/$(kubectl get nodes --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[0].metadata.name}')"
  nodes_to_delete="$(kubectl get nodes -o jsonpath='{.items[?(@.status.conditions[0].status=="Unknown")].metadata.name}')"
  if [ -n "${nodes_to_delete}" ]; then 
    kubectl delete node "${nodes_to_delete}"
  fi
  echo

  echo " * Checking running pods"
  kubectl get pods --all-namespaces
fi
