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
	tariff-secret status logs metrics targets reload verify discover probe \
	toggle names sync-names set-name clear-name dashboards datasource port-forward \
	print-scrape-config uninstall

help:
	@echo "make install             push-image + deploy -- the from-scratch path"
	@echo "make build-image         podman build the exporter image"
	@echo "make push-image          push it to $(REGISTRY)"
	@echo "make deploy              apply namespace, tariff, rules, devices, exporter, Prometheus, dashboard, datasource"
	@echo "make verify              exporter reachable, Prometheus target up, rules loaded"
	@echo "make status              pods/pvc/svc in the $(NAMESPACE) namespace"
	@echo "make logs                tail the exporter"
	@echo "make metrics             dump the exporter's current /metrics"
	@echo "make targets             what this Prometheus thinks of its scrape target"
	@echo "make reload              re-read config without a restart; deploy already rolls the pod,"
	@echo "                         and a reload too soon after an apply re-reads the old file"
	@echo "make discover            sweep $(SUBNET).0/24 for Shelly devices and their models"
	@echo "make probe HOST=<ip>     raw Shelly.GetStatus from one device"
	@echo "make toggle HOST=<ip> CH=<n>   flip one channel, to work out which socket is which"
	@echo "make names               what each device calls itself and its sockets"
	@echo "make sync-names [DRY=1]  write the names in $(DEVICES) onto the devices"
	@echo "make set-name HOST=<ip> CH=<n> NAME=\"Freezer\"   name a socket on the device itself"
	@echo "make clear-name HOST=<ip> CH=<n>   clear it again"
	@echo "make dashboards          hand dashboards/*.json to Grafana's sidecar as a ConfigMap"
	@echo "make datasource          hand the Energy datasource to Grafana's sidecar as a ConfigMap"
	@echo "make port-forward        open the energy Prometheus UI on :9091"
	@echo "make print-scrape-config scrape job to paste elsewhere, if you drop this Prometheus"
	@echo "make uninstall           delete the namespace (this deletes the energy history)"

# ------------------------------------------------------------------ deploy

install: push-image deploy
	@echo
	@echo "Deployed. Check it with: make verify"

build-image:
	podman build -t $(IMAGE) $(EXPORTER_DIR)

# The registry listens on 127.0.0.1 over plain HTTP, hence --tls-verify=false.
push-image: build-image
	podman push --tls-verify=false $(IMAGE)

ENV_FILE := .env

# The tariff lives in the gitignored .env and reaches the pod as a Secret, so
# the price is on the host and in the cluster but never in the repo.
tariff-secret:
	@test -f $(ENV_FILE) || { \
		echo "$(ENV_FILE) is missing -- copy .env.example to $(ENV_FILE) and set your price per kWh" >&2; \
		exit 1; }
	@grep -qE '^PRICE_FLAT_EUR_PER_KWH=[0-9]*\.?[0-9]+' $(ENV_FILE) \
		|| grep -qE '^PRICE_MODE=spot' $(ENV_FILE) \
		|| { echo "$(ENV_FILE): set PRICE_FLAT_EUR_PER_KWH, or PRICE_MODE=spot" >&2; exit 1; }
	$(KUBECTL) apply -f manifests/namespace.yaml
	@$(KUBECTL) create secret generic shelly-tariff -n $(NAMESPACE) \
		--from-env-file=$(ENV_FILE) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	@# The tariff used to be a committed ConfigMap of the same name.
	@$(KUBECTL) -n $(NAMESPACE) delete configmap shelly-tariff --ignore-not-found

devices-configmap:
	@$(KUBECTL) create configmap shelly-devices -n $(NAMESPACE) \
		--from-file=devices.yaml=$(DEVICES) \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -

deploy: tariff-secret
	$(KUBECTL) apply -f manifests/rules.yaml
	@$(MAKE) --no-print-directory devices-configmap KUBECTL="$(KUBECTL)"
	@# Catches the "deployed a commit whose image was never pushed" case, which
	@# otherwise only shows up as ImagePullBackOff a minute later.
	@curl -sf "http://$(REGISTRY)/v2/shelly-prometheus-grafana/shelly-exporter/tags/list" \
		| grep -q '"$(TAG)"' \
		|| { echo "image $(IMAGE) is not in the registry -- run: make push-image" >&2; exit 1; }
	@# A mounted ConfigMap is only read at startup, so the checksum in the pod
	@# template is what makes a devices.yaml edit actually take effect.
	sed -e "s|__DEVICES_CHECKSUM__|$$(sha256sum $(DEVICES) | cut -c1-16)|" \
		-e "s|__TARIFF_CHECKSUM__|$$(sha256sum $(ENV_FILE) | cut -c1-16)|" \
		-e "s|__IMAGE__|$(IMAGE)|" \
		manifests/exporter.yaml | $(KUBECTL) apply -f -
	sed -e "s|__CONFIG_CHECKSUM__|$$(cat manifests/prometheus.yaml manifests/rules.yaml \
		| sha256sum | cut -c1-16)|" \
		manifests/prometheus.yaml | $(KUBECTL) apply -f -
	@$(MAKE) --no-print-directory dashboards KUBECTL="$(KUBECTL)"
	@$(MAKE) --no-print-directory datasource KUBECTL="$(KUBECTL)"
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

# What each device calls itself and its outputs. A name set here wins over the
# channels: mapping in devices.yaml, so this is the list the graphs use.
names:
	@sed -n 's/^  - name: \(.*\)/\1/p; s/^    host: \(.*\)/\1/p' $(DEVICES) \
	| paste - - \
	| while read -r name host; do \
		cfg=$$(curl -s -m 5 "http://$$host/rpc/Shelly.GetConfig"); \
		dev=$$(printf '%s' "$$cfg" | sed -n 's/.*"device":{"name":\("[^"]*"\|null\).*/\1/p'); \
		printf '%-14s %-15s device=%s\n' "$$name" "$$host" "$$dev"; \
		printf '%s' "$$cfg" | tr '{' '\n' | sed -n 's/^"switch:\([0-9]*\)":$$/\1/p' >/dev/null; \
		for id in 0 1 2 3; do \
			n=$$(curl -s -m 5 "http://$$host/rpc/Switch.GetConfig?id=$$id" \
				| sed -n 's/.*"name":\("[^"]*"\|null\).*/\1/p'); \
			[ -n "$$n" ] && printf '    switch:%s  %s\n' "$$id" "$$n"; \
		done; \
	done

# Writes every name in devices.yaml onto the devices. The names set in the
# Shelly app live in your Shelly Cloud account, not on the hardware, so this is
# what makes a name local -- and local is what the exporter, the app and a
# rebuilt cluster all read. Re-runnable; DRY=1 shows what it would change.
sync-names:
	@python3 scripts/sync-names.py $(DEVICES) $(if $(DRY),--dry-run,)

# Names a single output on the device itself.
set-name: export SHELLY_NAME = $(NAME)
set-name: export SHELLY_CH = $(CH)
set-name:
	@test -n "$(HOST)" -a -n "$(CH)" -a -n "$$SHELLY_NAME" || { \
		echo 'usage: make set-name HOST=192.168.0.128 CH=1 NAME="Freezer"' >&2; exit 1; }
	@# Two things make this fiddly. The name reaches the shell through the
	@# environment, never interpolated into the command line, so quotes in it
	@# cannot break the quoting. And it goes as a POSTed JSON-RPC body rather
	@# than in the query string, because the firmware's query-string parser
	@# rejects an escaped quote inside config= with a misleading
	@# "Missing required argument 'id'".
	@python3 -c 'import json,os,sys; json.dump({"id":1,"method":"Switch.SetConfig",\
		"params":{"id":int(os.environ["SHELLY_CH"]),\
		"config":{"name":os.environ["SHELLY_NAME"]}}}, sys.stdout)' \
	| curl -sf -X POST "http://$(HOST)/rpc" -H 'Content-Type: application/json' \
		--data-binary @- \
	| grep -q '"result"' \
		|| { echo "the device rejected the call" >&2; exit 1; }
	@echo " -> set; the exporter relabels within META_TTL_MS (5 min by default)"

# Clears a name, handing the label back to devices.yaml.
clear-name: export SHELLY_CH = $(CH)
clear-name:
	@test -n "$(HOST)" -a -n "$(CH)" || { \
		echo 'usage: make clear-name HOST=192.168.0.128 CH=1' >&2; exit 1; }
	@python3 -c 'import json,os,sys; json.dump({"id":1,"method":"Switch.SetConfig",\
		"params":{"id":int(os.environ["SHELLY_CH"]),"config":{"name":None}}}, sys.stdout)' \
	| curl -sf -X POST "http://$(HOST)/rpc" -H 'Content-Type: application/json' \
		--data-binary @- \
	| grep -q '"result"' \
		|| { echo "the device rejected the call" >&2; exit 1; }
	@echo " -> cleared"

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
# Same mechanism as the dashboard: a labelled ConfigMap, picked up from any
# namespace. Grafana's datasource sidecar writes the file and calls the
# provisioning reload API, so this needs no restart and no API token.
datasource:
	$(KUBECTL) apply -f manifests/datasource.yaml

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
