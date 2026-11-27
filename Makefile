SHELL := /bin/bash
# pipefail so a failed kubectl in a pipeline aborts instead of applying
# whatever the next stage happened to produce.
.SHELLFLAGS := -o pipefail -c

NAMESPACE := energy
# Built with podman on the cluster host and pushed to the in-cluster registry,
# the same way everything else on this box is delivered. The tag is the commit,
# so a rollback is a checkout and a pod never reuses a stale "latest".
REGISTRY ?= localhost:30500
IMAGE_REPO := $(REGISTRY)/shelly-prometheus-grafana/shelly-exporter
TAG ?= $(shell git rev-parse --short HEAD)
IMAGE := $(IMAGE_REPO):$(TAG)
EXPORTER_DIR := exporter
DEVICES := devices.yaml

# k3s keeps its kubeconfig at /etc/rancher/k3s/k3s.yaml, root-readable only.
# Override if your shell is not already pointed at a readable copy:
#   make deploy KUBECTL="sudo k3s kubectl"
KUBECTL ?= kubectl

# Subnet that `make discover` sweeps for devices.
SUBNET ?= 192.168.0

.PHONY: help install deploy build-image push-image devices-configmap \
	status logs metrics targets reload verify discover probe toggle \
	dashboards datasource port-forward print-scrape-config uninstall

help:
	@echo "make install             push-image + deploy -- the from-scratch path"
	@echo "make build-image         podman build the exporter image"
	@echo "make push-image          push it to $(REGISTRY)"
	@echo "make deploy              apply namespace, tariff, rules, devices, exporter, Prometheus, dashboard"
	@echo "make verify              exporter reachable, Prometheus target up, rules loaded"
	@echo "make status              pods/pvc/svc in the $(NAMESPACE) namespace"
	@echo "make logs                tail the exporter"
	@echo "make metrics             dump the exporter's current /metrics"
	@echo "make targets             what this Prometheus thinks of its scrape target"
	@echo "make reload              re-read prometheus.yml and the rules without a restart"
	@echo "make discover            sweep $(SUBNET).0/24 for Shelly devices and their models"
	@echo "make probe HOST=<ip>     raw Shelly.GetStatus from one device"
	@echo "make toggle HOST=<ip> CH=<n>   flip one channel, to work out which socket is which"
	@echo "make dashboards          hand dashboards/*.json to Grafana's sidecar as a ConfigMap"
	@echo "make datasource          print the Grafana datasource to add, once"
	@echo "make port-forward        open the energy Prometheus UI on :9091"
	@echo "make print-scrape-config scrape job to paste elsewhere, if you drop this Prometheus"
	@echo "make uninstall           delete the namespace (this deletes the energy history)"

# ------------------------------------------------------------------ deploy

install: push-image deploy
	@echo
	@echo "Deployed. Check it with: make verify"
	@echo "If this is the first install, add the Grafana datasource: make datasource"

build-image:
	podman build -t $(IMAGE) $(EXPORTER_DIR)

# The registry listens on 127.0.0.1 over plain HTTP, hence --tls-verify=false.
push-image: build-image
	podman push --tls-verify=false $(IMAGE)

devices-configmap:
	@$(KUBECTL) create configmap shelly-devices -n $(NAMESPACE) \
		--from-file=devices.yaml=$(DEVICES) \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -

deploy:
	$(KUBECTL) apply -f manifests/namespace.yaml
	$(KUBECTL) apply -f manifests/tariff.yaml -f manifests/rules.yaml
	@$(MAKE) --no-print-directory devices-configmap KUBECTL="$(KUBECTL)"
	@# Catches the "deployed a commit whose image was never pushed" case, which
	@# otherwise only shows up as ImagePullBackOff a minute later.
	@curl -sf "http://$(REGISTRY)/v2/shelly-prometheus-grafana/shelly-exporter/tags/list" \
		| grep -q '"$(TAG)"' \
		|| { echo "image $(IMAGE) is not in the registry -- run: make push-image" >&2; exit 1; }
	@# A mounted ConfigMap is only read at startup, so the checksum in the pod
	@# template is what makes a devices.yaml edit actually take effect.
	sed -e "s|__DEVICES_CHECKSUM__|$$(sha256sum $(DEVICES) | cut -c1-16)|" \
		-e "s|__IMAGE__|$(IMAGE)|" \
		manifests/exporter.yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f manifests/prometheus.yaml
	@$(MAKE) --no-print-directory dashboards KUBECTL="$(KUBECTL)"
	$(KUBECTL) -n $(NAMESPACE) rollout status deploy/shelly-exporter --timeout=120s
	$(KUBECTL) -n $(NAMESPACE) rollout status deploy/energy-prometheus --timeout=180s

# ------------------------------------------------------------------ checks

status:
	$(KUBECTL) -n $(NAMESPACE) get deploy,pod,pvc,svc,cm

logs:
	$(KUBECTL) -n $(NAMESPACE) logs -f deploy/shelly-exporter

metrics:
	@$(KUBECTL) -n $(NAMESPACE) exec deploy/shelly-exporter -- \
		wget -qO- http://127.0.0.1:9102/metrics

targets:
	@$(KUBECTL) -n $(NAMESPACE) exec deploy/energy-prometheus -- \
		wget -qO- 'http://127.0.0.1:9090/api/v1/targets?state=active'

reload:
	$(KUBECTL) -n $(NAMESPACE) exec deploy/energy-prometheus -- \
		wget -qO- --post-data='' http://127.0.0.1:9090/-/reload
	@echo "reloaded"

# Each device should report shelly_up 1, the scrape target should be "up",
# and the recording rules should be registered.
verify:
	@echo "--- devices ---"
	@$(KUBECTL) -n $(NAMESPACE) exec deploy/shelly-exporter -- \
		wget -qO- http://127.0.0.1:9102/metrics | grep -E '^shelly_up\{|^shelly_price_up '
	@echo "--- scrape target ---"
	@$(KUBECTL) -n $(NAMESPACE) exec deploy/energy-prometheus -- \
		wget -qO- 'http://127.0.0.1:9090/api/v1/targets?state=active' \
		| grep -o '"health":"[a-z]*"' || echo "no active target"
	@echo "--- recording rules ---"
	@$(KUBECTL) -n $(NAMESPACE) exec deploy/energy-prometheus -- \
		wget -qO- http://127.0.0.1:9090/api/v1/rules \
		| grep -o '"name":"shelly:[a-z_0-9:]*"' | sort -u || echo "no rules loaded"

# ------------------------------------------------------------------ devices

# /shelly answers on every generation and needs no auth by default, so it is
# the cheapest way to tell a Shelly from anything else on the subnet.
discover:
	@echo "sweeping $(SUBNET).0/24 ..."
	@seq 1 254 | xargs -P 64 -I{} sh -c \
		'r=$$(curl -s -m 2 "http://$(SUBNET).{}/shelly" 2>/dev/null); \
		 case "$$r" in *\{*) echo "$(SUBNET).{} $$r";; esac' \
		| sort -t. -k4 -n

probe:
	@test -n "$(HOST)" || { echo "usage: make probe HOST=192.168.0.21" >&2; exit 1; }
	@curl -s -m 5 "http://$(HOST)/rpc/Shelly.GetStatus"; echo

# Flipping a socket is the only reliable way to map switch ids to the
# physical outlets on the 4-socket strip.
toggle:
	@test -n "$(HOST)" -a -n "$(CH)" || \
		{ echo "usage: make toggle HOST=192.168.0.128 CH=0" >&2; exit 1; }
	@curl -s -m 5 "http://$(HOST)/rpc/Switch.Toggle?id=$(CH)"; echo

# ------------------------------------------------------------------ grafana

# Grafana's datasources are file-provisioned from the monitoring kustomization
# in the k3s-gameservers repo, so this one addition is not something this repo
# can apply for you. It is a one-time, four-line change; the dashboard defaults
# to the uid below.
datasource:
	@echo "Add this to k3s-gameservers/infrastructure/monitoring/config/datasources.yaml"
	@echo "and re-run that kustomization (or add it once in the Grafana UI):"
	@echo
	@echo "  - name: Energy"
	@echo "    type: prometheus"
	@echo "    uid: energy-prometheus"
	@echo "    access: proxy"
	@echo "    url: http://energy-prometheus.$(NAMESPACE).svc:9090"

# Grafana runs the kiwigrid sidecar, which loads any ConfigMap labelled
# grafana_dashboard=1 from any namespace and files it under the folder named in
# the grafana_folder annotation. So the dashboard ships as a ConfigMap and
# needs no API token and no manual import.
dashboards:
	@$(KUBECTL) create configmap energy-dashboards -n $(NAMESPACE) \
		$$(for f in dashboards/*.json; do echo "--from-file=$$(basename $$f)=$$f"; done) \
		--dry-run=client -o yaml \
	| $(KUBECTL) label --local -f - grafana_dashboard=1 -o yaml \
	| $(KUBECTL) annotate --local -f - grafana_folder=Energy -o yaml \
	| $(KUBECTL) apply -f -

port-forward:
	$(KUBECTL) -n $(NAMESPACE) port-forward svc/energy-prometheus 9091:9090

# If you would rather scrape the exporter from an existing Prometheus than run
# the one in manifests/prometheus.yaml, this is the job to add. Read
# docs/architecture.md on retention before you do.
print-scrape-config:
	@echo "      - job_name: shelly"
	@echo "        static_configs:"
	@echo '          - targets: ["shelly-exporter.$(NAMESPACE).svc.cluster.local:9102"]'

uninstall:
	@echo "This deletes the $(NAMESPACE) namespace, including the energy history in its PVC."
	@read -r -p "Type $(NAMESPACE) to confirm: " a; [ "$$a" = "$(NAMESPACE)" ] || { echo "aborted" >&2; exit 1; }
	$(KUBECTL) delete namespace $(NAMESPACE)
