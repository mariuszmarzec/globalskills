---
name: interview-kubernetes
description: DevOps interview cheat sheet for Kubernetes covering architecture (control plane, nodes), core concepts (Pods, Deployments, Services, Ingress), configuration (ConfigMaps, Secrets), networking, storage, scheduling, autoscaling, RBAC, and common interview questions with concise answers.
---

# Kubernetes — Interview Cheat Sheet

## DevOps Interview Subject

## 1. What is Kubernetes?

> **Kubernetes is a container orchestration platform that manages containerized applications across a cluster of machines.**

It provides:

* deployment
* scaling
* service discovery
* load balancing
* self-healing
* rolling updates
* configuration management
* secrets management

**Docker runs containers. Kubernetes manages containers.**

---

## 2. Cluster architecture

A Kubernetes cluster consists of:

```text
              CONTROL PLANE
        ┌─────────────────────┐
        │ API Server          │
        │ Scheduler           │
        │ Controller Manager  │
        │ etcd                │
        └──────────┬──────────┘
                   │
          ┌────────┼────────┐
          ▼        ▼        ▼
       Worker    Worker    Worker
        Node      Node      Node
```

### Control Plane

**API Server**

* Entry point to Kubernetes.
* `kubectl` communicates with it.
* Other Kubernetes components communicate through the API.

**etcd**

* Distributed key-value database.
* Stores the cluster state.

**Scheduler**

* Decides **which Node should run a Pod**.

**Controller Manager**

* Runs controllers that continuously compare:

```text
Desired state vs Actual state
```

and reconcile the difference.

### Worker Node

**kubelet**

* Agent running on every Node.
* Makes sure assigned Pods are actually running.

**Container runtime**

* Runs containers.
* Usually `containerd` or CRI-O.

**kube-proxy**

* Helps implement Service networking.

---

# 3. Pod

> **A Pod is the smallest deployable unit in Kubernetes.**

Usually:

```text
Pod
└── Container
```

But it can contain multiple tightly coupled containers:

```text
Pod
├── Application container
└── Sidecar container
```

Containers inside the same Pod:

* share the same network namespace
* share the same IP
* can communicate through `localhost`
* can share volumes

**Important:** Pod ≠ Container.

---

# 4. Node

A **Node** is a machine where Pods run.

It can be:

* physical server
* virtual machine
* cloud VM
* local machine

Example:

```text
Cluster
├── Node 1
│   ├── Pod
│   └── Pod
├── Node 2
│   └── Pod
└── Node 3
    ├── Pod
    └── Pod
```

A Node registers with the Control Plane and runs `kubelet`.

---

# 5. Deployment

Deployment manages application Pods.

```text
Deployment
    ↓
ReplicaSet
    ↓
Pods
```

Example:

```yaml
spec:
  replicas: 3
```

means:

> Keep 3 Pods running.

If one dies:

```text
3 → 2
```

the controller creates another:

```text
2 → 3
```

This is **self-healing**.

Deployment also provides:

* rolling updates
* rollback
* scaling

---

# 6. ReplicaSet

ReplicaSet's job is simple:

> **Ensure that the desired number of Pods exists.**

Usually you don't create ReplicaSets directly.

You create:

```text
Deployment
    ↓
ReplicaSet
    ↓
Pods
```

---

# 7. Service

Pods are ephemeral and their IP addresses can change.

A **Service provides a stable network endpoint for a group of Pods.**

```text
             Service
             backend:80
                 │
          ┌──────┴──────┐
          ▼             ▼
       Pod :8080     Pod :8080
```

Service uses **labels/selectors** to find Pods.

Example:

```yaml
selector:
  app: backend
```

### Service types

**ClusterIP**

* Default.
* Accessible inside the cluster.

**NodePort**

* Exposes a port on each Node.

**LoadBalancer**

* Usually integrates with a cloud load balancer.

**Headless Service**

* `clusterIP: None`
* Often used with StatefulSets.

---

# 8. Ingress

Ingress handles HTTP/HTTPS routing.

Typical architecture:

```text
Internet
   ↓
Ingress
   ↓
Service
   ↓
Pods
```

Example:

```text
api.example.com     → backend-service
www.example.com     → frontend-service
```

Important:

> **Ingress is an API/resource defining HTTP routing. An Ingress Controller actually implements that routing.**

Examples of controllers include NGINX-based controllers and cloud-specific controllers.

---

# 9. ConfigMap vs Secret

### ConfigMap

Stores non-sensitive configuration:

```text
LOG_LEVEL=INFO
DATABASE_HOST=postgres
```

### Secret

Stores sensitive data:

```text
DATABASE_PASSWORD
API_TOKEN
```

Important interview detail:

> Kubernetes Secrets are **not automatically encrypted just because they are Secrets**. Their values are commonly represented as base64, which is encoding, not encryption. Encryption at rest can be configured.

---

# 10. Namespace

Namespaces provide logical isolation inside a cluster.

```text
Cluster
├── production
│   ├── backend
│   └── frontend
├── staging
│   ├── backend
│   └── frontend
└── monitoring
```

Useful for:

* organization
* RBAC
* resource quotas
* environment separation

---

# 11. Labels and Selectors

Labels identify Kubernetes objects:

```yaml
labels:
  app: backend
```

A Service can select them:

```yaml
selector:
  app: backend
```

Therefore:

```text
Service
   │
   │ selector: app=backend
   ▼
Pod       Pod       Pod
app=backend
```

This is fundamental to Kubernetes.

---

# 12. Health probes

### Liveness probe

> **Is the application still alive?**

Failure can cause Kubernetes to restart the container.

### Readiness probe

> **Is the application ready to receive traffic?**

If it fails, the Pod is removed from the Service endpoints.

The container does **not necessarily restart**.

### Startup probe

Useful for applications that take a long time to start.

Typical setup:

```text
Startup
   ↓
Readiness
   ↓
Liveness
```

---

# 13. Resources

Containers can define:

```yaml
resources:
  requests:
    cpu: "250m"
    memory: "256Mi"

  limits:
    cpu: "500m"
    memory: "512Mi"
```

### Request

> Amount of resources the Pod requests.

Scheduler uses requests when deciding where to place the Pod.

### Limit

> Maximum resource usage allowed.

If a container exceeds its memory limit:

```text
memory limit exceeded
        ↓
    OOMKilled
```

CPU limits behave differently: CPU is throttled rather than the container being killed simply because it exceeded the CPU limit.

---

# 14. HPA

**Horizontal Pod Autoscaler**

Automatically changes the number of Pod replicas based on metrics.

```text
CPU increases
     ↓
HPA
     ↓
3 Pods → 6 Pods
```

Horizontal scaling:

```text
3 Pods → 6 Pods
```

Vertical scaling:

```text
500 MB → 1 GB
```

---

# 15. StatefulSet

Use **Deployment** for mostly stateless applications:

```text
API
Backend
Frontend
```

Use **StatefulSet** when Pods need stable identity and/or persistent storage.

Examples:

* databases
* Kafka
* some distributed systems

Pods can have stable names:

```text
mysql-0
mysql-1
mysql-2
```

---

# 16. DaemonSet

> **Run one Pod on every eligible Node.**

Typical use cases:

* log collectors
* monitoring agents
* node-level networking agents

```text
Node 1 → logging-agent
Node 2 → logging-agent
Node 3 → logging-agent
```

---

# 17. Job / CronJob

### Job

Runs a task until completion.

Examples:

* database migration
* batch processing
* data import

```text
Job
 ↓
Pod
 ↓
Completed
```

### CronJob

Runs Jobs according to a schedule.

```text
every hour
    ↓
Job
    ↓
Pod
```

---

# 18. Storage

Pods/containers are generally ephemeral.

For persistent data:

```text
Pod
 ↓
PVC
 ↓
PV
 ↓
Storage
```

### PVC — PersistentVolumeClaim

> "I need storage with these properties."

### PV — PersistentVolume

> Actual storage resource available to Kubernetes.

---

# 19. Scheduling

The **Scheduler** decides where Pods should run.

It considers things like:

* CPU/memory requests
* node selectors
* affinity/anti-affinity
* taints/tolerations
* topology constraints

Example:

```yaml
nodeSelector:
  disktype: ssd
```

means:

> Schedule this Pod only on Nodes with `disktype=ssd`.

---

# 20. Taints and Tolerations

**Taint:**

> Don't schedule normal Pods on this Node.

**Toleration:**

> This Pod is allowed to run on a tainted Node.

Useful for dedicated Nodes, e.g.:

```text
GPU Node
Database Node
Infrastructure Node
```

---

# 21. Networking

Important Kubernetes networking concept:

> **Every Pod gets its own IP address. Pods can communicate directly with other Pods.**

But Pod IPs are ephemeral.

Therefore:

```text
Pod IP
   ↓
not reliable
```

Use:

```text
Service
```

for stable access.

Kubernetes also provides DNS, commonly through **CoreDNS**.

Example:

```text
backend.default.svc.cluster.local
```

---

# 22. RBAC

**Role-Based Access Control**

Controls who can do what through the Kubernetes API.

Main objects:

```text
Role
ClusterRole
RoleBinding
ClusterRoleBinding
ServiceAccount
```

Example:

```text
User
 ↓
Role
 ↓
Permissions
 ↓
Kubernetes API
```

---

# 23. Declarative model

One of the **most important Kubernetes concepts**.

Instead of saying:

> Start 3 containers.

You declare:

```yaml
replicas: 3
```

Then Kubernetes continuously works toward that state.

```text
Desired state
     ↓
Kubernetes
     ↓
Actual state
```

If:

```text
desired = 3
actual = 2
```

Kubernetes tries to make:

```text
actual = 3
```

This is called **reconciliation**.

---

# 24. Rolling update

Suppose:

```text
v1 → v2
```

Kubernetes gradually replaces old Pods with new ones.

```text
v1 v1 v1 v1
 ↓
v2 v1 v1 v1
 ↓
v2 v2 v1 v1
 ↓
v2 v2 v2 v1
 ↓
v2 v2 v2 v2
```

If something goes wrong:

```bash
kubectl rollout undo deployment/backend
```

---

# 25. Important kubectl commands

```bash
kubectl get nodes
kubectl get pods
kubectl get deployments
kubectl get services
```

Debugging:

```bash
kubectl describe pod <pod>
kubectl logs <pod>
kubectl logs -f <pod>
```

Execute command inside container:

```bash
kubectl exec -it <pod> -- sh
```

Deploy configuration:

```bash
kubectl apply -f deployment.yaml
```

Delete:

```bash
kubectl delete -f deployment.yaml
```

Check rollout:

```bash
kubectl rollout status deployment/backend
```

---

# 26. The most important architecture diagram

Memorize this:

```text
                     INTERNET
                        │
                        ▼
                     INGRESS
                        │
                        ▼
                     SERVICE
                        │
              ┌─────────┴─────────┐
              ▼                   ▼
             POD                 POD
              │                   │
          Container           Container
              │                   │
              └─────────┬─────────┘
                        │
                   Deployment
                        │
                    ReplicaSet
```

And above all of this:

```text
                  CONTROL PLANE
        ┌────────────────────────────┐
        │ API Server                 │
        │ Scheduler                  │
        │ Controller Manager         │
        │ etcd                       │
        └──────────────┬─────────────┘
                       │
             ┌─────────┼─────────┐
             ▼         ▼         ▼
           NODE      NODE      NODE
           kubelet   kubelet   kubelet
             │         │         │
            Pods      Pods      Pods
```

---

# 27. Interview questions you should be able to answer

### What happens when a Pod dies?

> A controller detects that the actual state differs from the desired state and creates a replacement Pod.

### Why do we need a Service?

> Pod IPs are ephemeral. A Service provides a stable endpoint and routes traffic to matching Pods.

### Deployment vs StatefulSet?

> Deployment is primarily for stateless workloads. StatefulSet provides stable identity and persistent storage semantics for stateful workloads.

### Liveness vs Readiness?

> Liveness determines whether the container should be restarted. Readiness determines whether the Pod should receive traffic.

### ConfigMap vs Secret?

> ConfigMap stores non-sensitive configuration. Secret is intended for sensitive data such as credentials and tokens.

### Request vs Limit?

> Requests influence scheduling and represent the resources a Pod needs. Limits cap resource usage.

### What is a Pod?

> The smallest deployable unit in Kubernetes, containing one or more containers that share networking and storage.

### What is a Node?

> A machine that runs Kubernetes workloads and typically contains kubelet and a container runtime.

### What is the Scheduler?

> It selects a suitable Node for a Pod based on resource requirements and scheduling constraints.

### How does Kubernetes self-heal?

> Controllers continuously reconcile the actual state with the desired state.

### How does traffic reach an application?

Typical path:

```text
Internet
   ↓
Ingress
   ↓
Service
   ↓
Pods
```

### Does Kubernetes require cloud?

> No. Kubernetes can run on physical machines, VMs, laptops, or cloud infrastructure. Cloud providers such as AWS, Azure and Google Cloud also offer managed Kubernetes services.

---

## 28. 30-second answer: "Explain Kubernetes"

> **Kubernetes is a declarative container orchestration platform. A cluster consists of a control plane and worker nodes. The control plane exposes the API, stores cluster state, schedules Pods and runs controllers. Worker nodes run Pods using kubelet and a container runtime. Deployments manage replicated Pods, Services provide stable networking, Ingress handles HTTP routing, and Kubernetes continuously reconciles the actual state with the desired state.**

Jeśli opanujesz **Pod → Deployment → Service → Ingress → Node → Control Plane → probes → requests/limits → HPA → declarative/reconciliation**, to masz już bardzo solidną bazę na typowe pytania z Kubernetes na rozmowie.
