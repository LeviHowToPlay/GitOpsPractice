#!/usr/bin/env bash
# 从零重建整个集群。
#
# 手动步骤只剩两件事，它们是「引导问题」——GitOps 需要一个已经在运行的
# Argo CD 才能开始工作，所以首次安装 Argo CD 永远无法由它自己完成。
# 其余一切（ingress-nginx、AppProject、所有应用）都由 root-app 从 Git 带出来。
set -euo pipefail
cd "$(dirname "$0")/.."
T0=$(date +%s)
el() { echo $(( $(date +%s) - T0 )); }
step() { printf "\n\033[36m▸ %s\033[0m  (+%ss)\n" "$1" "$(el)"; }

step "引导 1/2 · 建 kind 集群"
kind create cluster --config kind-cluster.yaml

step "引导 2/2 · 安装 Argo CD"
# --server-side 是必须的：applicationsets CRD 的 annotation 超过 256KB，
# 客户端 apply 会报 metadata.annotations: Too long
kubectl create namespace argocd
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.1/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

step "交给 Git · 唯一一次手动 apply"
kubectl apply -f bootstrap/root-app.yaml

step "等待收敛（首次要拉仓库建缓存，比平时慢）"
while :; do
  out=$(kubectl -n argocd get applications.argoproj.io -o json 2>/dev/null \
        | jq -r '[.items[]|"\(.metadata.name):\(.status.sync.status // "-")/\(.status.health.status // "-")"]|join("  ")' 2>/dev/null || true)
  printf "\r  +%3ss  %-90s" "$(el)" "${out:-展开中}"
  echo "$out" | grep -q "demo-dev:Synced/Healthy"      || { sleep 5; continue; }
  echo "$out" | grep -q "ingress-nginx:Synced/Healthy" || { sleep 5; continue; }
  echo "$out" | grep -q "argocd:Synced"                || { sleep 5; continue; }
  break
done
echo

step "验收"
kubectl -n argocd get app -o custom-columns='NAME:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status,HEALTH:.status.health.status'
echo
echo "服务返回: $(curl -s --max-time 8 localhost:8080 || echo '（ingress 还需几秒）')"
printf "\n\033[32m✓ 总耗时 %s 秒\033[0m\n" "$(el)"
echo "Argo CD 密码: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
