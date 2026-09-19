# GitOps Thesis Demo Access Guide

This guide explains how to access the Kubernetes environments (`dev`, `qa`, `staging`, `prod`) and the Argo CD management plane for demonstration and local testing purposes.

---

## 1. Why Pods Do Not Receive LAN IPs

In Kubernetes, Pods run in an isolated virtual overlay network (in this cluster provided by Flannel/CNI inside k3d). Pod IPs are private to the cluster SDN and are dynamically allocated, ephemeral, and non-routable from the external local area network (LAN). They cannot and should not be directly addressed by devices on your local physical network.

## 2. Role of ClusterIP Services

Internal communication between application tiers (such as the frontend querying the backend API, or the backend connecting to PostgreSQL) is managed through standard Kubernetes `ClusterIP` Services.
- `ClusterIP` assigns a stable internal virtual IP address within the cluster's service CIDR (`10.43.0.0/16`).
- Service discovery functions via internal CoreDNS (e.g., `backend-service.dev.svc.cluster.local`).
- All internal services remain strictly typed as `ClusterIP`, ensuring adherence to security boundaries and preventing accidental public exposure of databases and private APIs.

## 3. Purpose of the Demo Access Helper

The script [`scripts/demo-access.sh`](file:///home/emad/DATA/Monograph/gitops-thesis/infra-code/scripts/demo-access.sh) is a host-side demonstration tool. It establishes user-space port-forwarding tunnels using `kubectl port-forward` from the host network into the Kubernetes cluster.
- It does **not** modify cluster networking or Kubernetes manifests.
- It does **not** install third-party network controllers (e.g., MetalLB).
- It provides a safe, reproducible, and non-destructive way to evaluate running environments from the host browser or a secondary device on the same local network.

## 4. Determining the Host LAN IP

When presenting demonstrations to other devices on the same Wi-Fi or Ethernet network, determine the current host LAN IP address using either of the following commands:

```bash
# View active IP addresses:
hostname -I

# Or inspect interface addresses specifically:
ip -4 addr
```

Identify the IP associated with your primary network interface (e.g., `enp0s31f6` or `wlan0`, typically `192.168.x.x` or `10.x.x.x`). Do not select loopback (`127.0.0.1`), Docker bridges (`172.17.x.x`, `172.18.x.x`), or VPN interfaces unless intended.

## 5. Local-Only Access (Default)

To access all services solely from the local host machine (bound to `127.0.0.1`):

```bash
./scripts/demo-access.sh start
```

This binds all forwarders to loopback, making endpoints accessible only on `http://localhost:<PORT>`.

## 6. LAN Access for Multi-Device Demonstration

To allow laptops, mobile phones, or workstations on the same local network to access the demo environments, supply the host's LAN IP via the `BIND_IP` environment variable:

```bash
BIND_IP=192.168.157.15 ./scripts/demo-access.sh start
```

*(Replace `192.168.157.15` with your active host LAN IP).*

Ensure that host firewall rules (e.g., UFW or iptables) allow incoming TCP connections on the demo ports (3000–3003, 8000–8003, 8081) if accessing from another device.

## 7. Checking Status

To view the running status, process IDs, and target mappings of all tunnels:

```bash
./scripts/demo-access.sh status
```

To re-print the formatted table of URLs at any time:

```bash
./scripts/demo-access.sh urls
```

## 8. Stopping Access Tunnels

To terminate all port-forwarding processes created by this script and remove runtime PID files:

```bash
./scripts/demo-access.sh stop
```

The script specifically identifies and terminates only the processes it launched, leaving all unrelated `kubectl` processes untouched.

## 9. Network Portability Across Networks

When the demonstration laptop switches between networks (e.g., from home Wi-Fi to campus/office Ethernet):
- **No Kubernetes manifests need to be modified.**
- **No Git commits or CI/CD pipelines are triggered.**
- **Cluster networking is completely unaffected.**

Simply stop the previous session and re-run with the newly assigned host IP:

```bash
./scripts/demo-access.sh stop
BIND_IP=$(hostname -I | awk '{print $1}') ./scripts/demo-access.sh start
```

## 10. Development/Demo vs. Production Ingress Architecture

> [!IMPORTANT]
> **Architectural Distinction:**
> - `kubectl port-forward` and `demo-access.sh` are **strictly for local development, thesis evaluation, and live demonstrations**.
> - In a real **production environment**, external traffic ingress must be handled via a production-grade Ingress Controller (e.g., Ingress-NGINX, Traefik, or Envoy Gateway) paired with a cloud or hardware LoadBalancer, automated TLS termination (such as `cert-manager` with Let's Encrypt), and ingress network policies.
> - Port forwarding does not offer high availability, connection pooling, rate limiting, or production security controls.

---

## Port Reference Table

| Environment | Component | Host Port | Target Service | Path |
| :--- | :--- | :--- | :--- | :--- |
| **DEV** | Frontend | `3000` | `dev/frontend-service:80` | `/` |
| **DEV** | Backend | `8000` | `dev/backend-service:8000` | `/health`, `/docs` |
| **QA** | Frontend | `3001` | `qa/frontend-service:80` | `/` |
| **QA** | Backend | `8001` | `qa/backend-service:8000` | `/health`, `/docs` |
| **STAGING** | Frontend | `3002` | `staging/frontend-service:80` | `/` |
| **STAGING** | Backend | `8002` | `staging/backend-service:8000` | `/health`, `/docs` |
| **PROD** | Frontend | `3003` | `prod/frontend-service:80` | `/` |
| **PROD** | Backend | `8003` | `prod/backend-service:8000` | `/health`, `/docs` |
| **ARGO CD** | UI / API | `8081` | `argocd/argocd-server:443` | `/` |
