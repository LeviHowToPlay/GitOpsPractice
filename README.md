# demo-gitops

集群的唯一真相。`demo-app` 的代码在 [JavaPractice](https://github.com/LeviHowToPlay/JavaPractice)。

```
bootstrap/root-app.yaml          唯一一个手动 kubectl apply 的东西
argocd/projects/demo.yaml        AppProject：限制能动哪些命名空间
argocd/applications/             demo-dev（自动同步）/ demo-prod（手动同步）
apps/demo-app/base/              deployment · service · ingress
apps/demo-app/overlays/dev/      CI 只改这里的 image tag
apps/demo-app/overlays/prod/     只有人手动提 PR 才会改
kind-cluster.yaml                本地集群定义（80 → 宿主机 8080）
```

## 从零把集群拉起来

手动步骤只有两件事，且都是**引导问题** —— GitOps 需要一个已经在运行的
Argo CD 才能开始工作，所以首次安装它永远无法自举。其余一切（ingress-nginx、
AppProject、所有应用）都由 root-app 从 Git 带出来。

```bash
./bootstrap/rebuild.sh      # 下面四步的封装，带计时
```

或者手动：

```bash
# 引导 1/2 · 集群
kind create cluster --config kind-cluster.yaml

# 引导 2/2 · Argo CD
#   必须用 --server-side：applicationsets CRD 的 annotation 超过 256KB，
#   普通 kubectl apply 会报 "metadata.annotations: Too long"。
kubectl create namespace argocd
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.1/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

# 交给 Git · 唯一一次手动 apply
kubectl apply -f bootstrap/root-app.yaml
```

重建后 `argocd` 这个应用会显示 **OutOfSync** —— 预期行为：刚 apply 出来的资源
还没有 Argo CD 的 tracking-id 注解。它刻意不开 automated（自管理一旦把自己
prune 掉就没救了），所以要人工确认后接管：

```bash
argocd app diff argocd     # 应该只有 tracking-id 注解，无功能性改动
argocd app sync argocd
```

UI 与初始密码：

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8081:443
# https://localhost:8081  用户名 admin（自签证书，浏览器警告继续即可）
```

## 访问

| 环境 | 地址 | 同步策略 |
| --- | --- | --- |
| dev  | http://localhost:8080 | automated + selfHeal |
| prod | http://prod.localtest.me:8080 | 手动 Sync |

`prod.localtest.me` 是公共 DNS，解析到 127.0.0.1，不用改 hosts 文件。

## 注意

两个 overlay 的初始 tag 都是 `bootstrap`，这个镜像并不存在 —— Pod 会 `ImagePullBackOff`，
这是预期的。等 `demo-app` 第一次 push 到 main、CI 把真实 git sha 回写到 dev overlay 之后，
dev 就会自己起来。prod 要等你手动把那个 sha 提 PR 过来。
