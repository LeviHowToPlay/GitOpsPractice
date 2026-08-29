#!/usr/bin/env bash
# 从零重建整个集群。实验 03：删掉集群跑这个，看多久能回到原样。
set -euo pipefail
cd "$(dirname "$0")/.."
T0=$(date +%s)
step() { printf "\n\033[36m▸ %s\033[0m  (+%ss)\n" "$1" "$(( $(date +%s) - T0 ))"; }

step "阶段 0-1 · 建 kind 集群"
kind create cluster --config kind-cluster.yaml

step "阶段 0-2 · ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
# kubectl wait 在资源还不存在时会立刻报错退出（不是等待），
# 而 controller Pod 要等 admission job 跑完才被创建 —— 先等它出现。
for i in $(seq 1 60); do
  kubectl -n ingress-nginx get pod -l app.kubernetes.io/component=controller \
    -o name 2>/dev/null | grep -q . && break
  sleep 2
done
kubectl -n ingress-nginx wait --for=condition=ready pod \
  -l app.kubernetes.io/component=controller --timeout=180s

step "阶段 2-1 · Argo CD"
# --server-side 是必须的：applicationsets CRD 的 annotation 超过 256KB
kubectl create namespace argocd
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.1/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

step "阶段 2-2 · root-app（唯一一次手动 apply）"
kubectl apply -f bootstrap/root-app.yaml

step "等待 Argo CD 把集群同步成 Git 描述的样子"
for i in $(seq 1 60); do
  s=$(kubectl -n argocd get app demo-dev -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  h=$(kubectl -n argocd get app demo-dev -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  printf "\r  demo-dev: %-10s %-12s (+%ss)  " "${s:-...}" "${h:-...}" "$(( $(date +%s) - T0 ))"
  [ "$s" = "Synced" ] && [ "$h" = "Healthy" ] && break
  sleep 5
done
echo

step "验收"
kubectl -n argocd get app -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
echo "服务返回: $(curl -s --max-time 5 localhost:8080 || echo '（ingress 可能还需几秒）')"
printf "\n\033[32m✓ 总耗时 %s 秒\033[0m\n" "$(( $(date +%s) - T0 ))"
echo "Argo CD 密码: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
