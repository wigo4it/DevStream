#!/usr/bin/env bash
set -euo pipefail

### CONFIG
CLUSTER_NAME="gitops-demo"
TERRAFORM_DIR="/home/jp/gitops/DevStream/terraform"
EDGE_CMD="powershell.exe -Command Start-Process msedge"

### LOGGING
log()   { echo -e "\e[1;34m=> $*\e[0m"; }
error() { echo -e "\e[1;31m✗ $*\e[0m" >&2; exit 1; }

prompt_choice() {
  local msg=$1 default=$2 choice
  while true; do
    read -rp "$msg [$default] " choice
    choice=${choice:-$default}
    case "$choice" in
      [uU]) return 0 ;;  # update
      [xX]) return 1 ;;  # skip
      *) echo "  Kies 'u' om te updaten of 'x' om door te gaan." ;;
    esac
  done
}

usage() {
  cat <<EOF
Gebruik: $0 [-d]

  -d    Delete k3d-cluster '$CLUSTER_NAME' en stop Docker-daemon, daarna exit
EOF
  exit 1
}

delete_and_stop() {
  log "Verwijder k3d-cluster '$CLUSTER_NAME'…"
  if k3d cluster list | grep -q "^${CLUSTER_NAME}\b"; then
    k3d cluster delete "$CLUSTER_NAME"
    log "Cluster verwijderd."
  else
    log "Cluster '$CLUSTER_NAME' bestaat niet."
  fi

  log "Stoppen van Docker-daemon…"
  if sudo systemctl stop docker 2>/dev/null; then
    log "Docker-daemon gestopt."
  elif sudo service docker stop 2>/dev/null; then
    log "Docker-daemon gestopt via service."
  else
    error "Kon Docker-daemon niet stoppen."
  fi

  log "Klaar met verwijderen en stoppen."
  exit 0
}

### PARSE OPTIES
if [[ "${1:-}" == "-"* ]]; then
  while getopts ":d" opt; do
    case "$opt" in
      d) delete_and_stop ;;
      *) usage ;;
    esac
  done
fi

### 1. Docker check & start
log "Controleren of Docker draait…"
if ! docker info &>/dev/null; then
  log "Docker draait niet. Proberen te starten…"
  if ! sudo service docker start 2>/dev/null && ! sudo systemctl start docker 2>/dev/null; then
    error "Kan Docker niet starten. Start Docker Desktop of installeer Docker."
  fi
  sleep 5
  docker info &>/dev/null || error "Docker start gefaald."
fi
log "Docker is actief"

### 2. Eénmalige systeem-update
log "Voer één keer apt-get update uit voor alle installaties"
sudo apt-get update -y

### 3. Installatie-helpers
install_jq()    { log "jq installeren…"    && sudo apt-get install -y jq; }
install_terraform(){ log "Terraform installeren…"&& sudo apt-get install -y terraform; }
install_helm()  { log "Helm installeren…"   && curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; }
install_k3d()   { log "k3d installeren…"    && curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash; }
install_kubectl(){ log "kubectl installeren…"&& sudo apt-get install -y kubectl; }
install_argocd(){
  log "argocd CLI installeren…"
  local ver tmpfile
  ver=$(curl -sSL https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r .tag_name | sed 's/^v//')
  tmpfile=$(mktemp)
  curl -sSL -o "$tmpfile" https://github.com/argoproj/argo-cd/releases/download/v${ver}/argocd-linux-amd64
  chmod +x "$tmpfile"
  sudo mv "$tmpfile" /usr/local/bin/argocd
  log "argocd CLI versie ${ver} geïnstalleerd"
}

### 4. Bepaal nieuwste versies (batch)
declare -A latest_versions
log "Bepaal nieuwste tool-versies (batch)"
latest_versions[terraform]=$(curl -s https://releases.hashicorp.com/index.json | jq -r '.terraform.versions|keys[]' | grep -Ev 'alpha|beta|rc' | sort -Vr | head -n1)
latest_versions[kubectl]=$(curl -sL https://dl.k8s.io/release/stable.txt | sed 's/^v//')
latest_versions[helm]=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name | sed 's/^v//')
latest_versions[k3d]=$(curl -s https://api.github.com/repos/k3d-io/k3d/releases/latest | jq -r .tag_name | sed 's/^v//')
latest_versions[jq]=$(curl -s https://api.github.com/repos/stedolan/jq/releases/latest | jq -r .tag_name | sed 's/^jq-//')
latest_versions[argocd]=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r .tag_name | sed 's/^v//')

### 5. Versiecheck & optionele update
check_and_maybe_update() {
  local cmd=$1 inst_ver="" latest_ver="${latest_versions[$cmd]}"

  if ! command -v "$cmd" &>/dev/null; then
    install_"$cmd"
    return
  fi

  # Haal geïnstalleerde versie op
  case "$cmd" in
    terraform) inst_ver=$(terraform version -json | jq -r .terraform_version)           ;;
    kubectl)   inst_ver=$(kubectl version --client -o json | jq -r .clientVersion.gitVersion | sed 's/^v//') ;;
    helm)      inst_ver=$(helm version --short | sed 's/^v//' | sed 's/+.*//')             ;;
    k3d)       inst_ver=$(k3d version | awk '/k3d version/ {print $3}' | sed 's/^v//' | sed 's/+.*//') ;;
    jq)        inst_ver=$(jq --version | sed 's/^jq-//')                                 ;;
    argocd)    inst_ver=$(argocd version --client 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//' | sed 's/+.*//') ;;
    *)         log "Geen versie-info voor $cmd beschikbaar"; return;;
  esac
  # Strip suffix vanaf '+'
  inst_ver="${inst_ver%%+*}"
  latest_ver="${latest_ver%%+*}"

  log "$cmd geïnstalleerd: versie $inst_ver"

  if [[ -z "$latest_ver" || "$latest_ver" == "null" ]]; then
    log "Kan nieuwste versie van $cmd niet ophalen, sla check over"
    return
  fi

  if [[ "$inst_ver" != "$latest_ver" ]]; then
    log "Nieuwere versie van $cmd beschikbaar: $latest_ver (geïnstalleerd: $inst_ver)"
    if prompt_choice "Update naar $latest_ver? (u=update, x=houd $inst_ver)" "u"; then
      install_"$cmd"
    else
      log "Behoud huidige versie van $cmd ($inst_ver)"
    fi
  else
    log "$cmd is up-to-date ($inst_ver)"
  fi
}

### 6. Check/install CLI’s
for cmd in jq terraform kubectl helm k3d argocd; do
  check_and_maybe_update "$cmd"
done

### 7. Maak k3d-cluster (met config in default ~/.kube-config)
if ! k3d cluster list | grep -q "^${CLUSTER_NAME}\b"; then
  log "Cluster '$CLUSTER_NAME' bestaat nog niet, maak aan…"
  k3d cluster create "$CLUSTER_NAME" \
    --servers 1 \
    --agents 2 \
    --port "30080:30080@loadbalancer" \
    --port "30443:30443@loadbalancer" \
    --kubeconfig-update-default
else
  log "Cluster '$CLUSTER_NAME' bestaat al"
fi

### 8. Terraform apply voor ArgoCD & Crossplane
if [ ! -d "$TERRAFORM_DIR" ]; then
  error "Directory '$TERRAFORM_DIR' bestaat niet. Plaats je main.tf daar."
fi

log "Ga naar Terraform folder en initialiseer/apply…"
pushd "$TERRAFORM_DIR" &>/dev/null
terraform init -input=false
terraform apply -auto-approve
popd &>/dev/null

### 10. Haal ArgoCD admin wachtwoord op & login
ARGO_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo
log "Argo CD admin-wachtwoord: $ARGO_PASS"

argocd login localhost:30443 \
  --username admin \
  --password "$ARGO_PASS" \
  --insecure

### 11. Open Argo CD in Edge
log "Argo CD UI openen in Edge…"
$EDGE_CMD "http://localhost:30443"

log "Klaar! 🎉"
