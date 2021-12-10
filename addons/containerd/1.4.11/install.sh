
CONTAINERD_NEEDS_RESTART=0
function containerd_install() {
    local src="$DIR/addons/containerd/$CONTAINERD_VERSION"

    if ! containerd_xfs_ftype_enabled; then
        bail "The filesystem mounted at /var/lib/containerd does not have ftype enabled"
    fi

    containerd_migrate_from_docker

    install_host_packages "$src" containerd.io

    case "$LSB_DIST" in
        centos|rhel|amzn|ol)
            yum_install_host_archives "$src" libzstd
            ;;
    esac

    chmod +x ${DIR}/addons/containerd/${CONTAINERD_VERSION}/assets/runc
    # If the runc binary is executing the cp command will fail with "text file busy" error.
    # Containerd uses runc in detached mode so any runc processes should be short-lived and exit
    # as soon as the container starts
    try_1m_stderr cp ${DIR}/addons/containerd/${CONTAINERD_VERSION}/assets/runc $(which runc)

    containerd_configure

    systemctl enable containerd

    containerd_configure_ctl "$src"

    # NOTE: this will not remove the proxy
    if [ -n "$PROXY_ADDRESS" ]; then
        containerd_configure_proxy
    fi

    if commandExists ${K8S_DISTRO}_registry_containerd_configure && [ -n "$DOCKER_REGISTRY_IP" ]; then
        ${K8S_DISTRO}_registry_containerd_configure "$DOCKER_REGISTRY_IP"
        CONTAINERD_NEEDS_RESTART=1
    fi

    if [ "$CONTAINERD_NEEDS_RESTART" = "1" ]; then
        systemctl daemon-reload
        restart_systemd_and_wait containerd
        CONTAINERD_NEEDS_RESTART=0
    fi

    # Explicitly configure kubelet to use containerd instead of detecting dockershim socket
    if [ -d "$DIR/kustomize/kubeadm/init-patches" ]; then
        cp "$DIR/addons/containerd/$CONTAINERD_VERSION/kubeadm-init-config-v1beta2.yaml" "$DIR/kustomize/kubeadm/init-patches/containerd-kubeadm-init-config-v1beta2.yml"
    fi

    if systemctl list-unit-files | grep -q kubelet.service; then
        systemctl start kubelet
        # If using the internal load balancer the Kubernetes API server will be unavailable until
        # kubelet starts the HAProxy static pod. This check ensures the Kubernetes API server
        # is available before proceeeding.
        try_5m kubectl --kubeconfig=/etc/kubernetes/kubelet.conf get nodes
    fi

    load_images $src/images
}

function containerd_configure() {
    if [ "$CONTAINERD_PRESERVE_CONFIG" = "1" ]; then
        echo "Skipping containerd configuration"
        return
    fi
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml

    sed -i '/systemd_cgroup/d' /etc/containerd/config.toml
    sed -i '/containerd.runtimes.runc.options/d' /etc/containerd/config.toml
    sed -i 's/level = ""/level = "warn"/' /etc/containerd/config.toml
    cat >> /etc/containerd/config.toml <<EOF
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF

	if [ -n "$CONTAINERD_TOML_CONFIG" ]; then
        local tmp=$(mktemp)
        echo "$CONTAINERD_TOML_CONFIG" > "$tmp"
        "$DIR/bin/toml" -basefile=/etc/containerd/config.toml -patchfile="$tmp"
    fi

    CONTAINERD_NEEDS_RESTART=1
}

function containerd_configure_ctl() {
    local src="$1"

    if [ -e "/etc/crictl.yaml" ]; then
        return 0
    fi

    cp "$src/crictl.yaml" /etc/crictl.yaml
}

containerd_configure_proxy() {
    local previous_proxy="$(cat /etc/systemd/system/containerd.service.d/http-proxy.conf 2>/dev/null | grep -io 'https*_proxy=[^\" ]*' | awk 'BEGIN { FS="=" }; { print $2 }')"
    local previous_no_proxy="$(cat /etc/systemd/system/containerd.service.d/http-proxy.conf 2>/dev/null | grep -io 'no_proxy=[^\" ]*' | awk 'BEGIN { FS="=" }; { print $2 }')"
    if [ "$PROXY_ADDRESS" = "$previous_proxy" ] && [ "$NO_PROXY_ADDRESSES" = "$previous_no_proxy" ]; then
        return
    fi

    mkdir -p /etc/systemd/system/containerd.service.d
    local file=/etc/systemd/system/containerd.service.d/http-proxy.conf

    echo "# Generated by kURL" > $file
    echo "[Service]" >> $file

    if echo "$PROXY_ADDRESS" | grep -q "^https"; then
        echo "Environment=\"HTTPS_PROXY=${PROXY_ADDRESS}\" \"NO_PROXY=${NO_PROXY_ADDRESSES}\"" >> $file
    else
        echo "Environment=\"HTTP_PROXY=${PROXY_ADDRESS}\" \"NO_PROXY=${NO_PROXY_ADDRESSES}\"" >> $file
    fi

    CONTAINERD_NEEDS_RESTART=1
}

# Returns 0 on non-xfs filesystems and on xfs filesystems if ftype=1.
containerd_xfs_ftype_enabled() {
    if ! commandExists xfs_info; then
        return 0
    fi

    mkdir -p /var/lib/containerd

    if xfs_info /var/lib/containerd 2>/dev/null | grep -q "ftype=0"; then
        return 1
    fi

    return 0
}

function containerd_migrate_from_docker() {
    if ! commandExists docker; then
        return
    fi

    if ! commandExists kubectl; then
        return
    fi

    echo "Draining node to prepare for migration from docker to containerd"

    # Delete pods that depend on other pods on the same node
    if [ -f "$DIR/addons/ekco/$EKCO_VERSION/reboot/shutdown.sh" ]; then
        bash $DIR/addons/ekco/$EKCO_VERSION/reboot/shutdown.sh
    elif [ -f /opt/ekco/shutdown.sh ]; then
        bash /opt/ekco/shutdown.sh
    else
        printf "${RED}EKCO shutdown script not available. Migration to containerd may fail\n${NC}"
    fi

    local node=$(hostname | tr '[:upper:]' '[:lower:]')
    kubectl cordon "$node" --kubeconfig=/etc/kubernetes/kubelet.conf

    local allPodUIDs=$(kubectl --kubeconfig=/etc/kubernetes/kubelet.conf get pods --all-namespaces -ojsonpath='{ range .items[*]}{.metadata.name}{"\t"}{.metadata.uid}{"\t"}{.metadata.namespace}{"\n"}{end}' )

    # Drain remaining pods using only the permissions available to kubelet
    while read -r uid; do
        local pod=$(echo "${allPodUIDs[*]}" | grep "$uid")
        if [ -z "$pod" ]; then
            continue
        fi
        local podName=$(echo "$pod" | awk '{ print $1 }')
        local podNamespace=$(echo "$pod" | awk '{ print $3 }')
        # some may timeout but proceed anyway
        kubectl --kubeconfig=/etc/kubernetes/kubelet.conf delete pod "$podName" --namespace="$podNamespace" --timeout=60s || true
    done < <(ls /var/lib/kubelet/pods)

    systemctl stop kubelet

    docker rm -f $(docker ps -a -q) || true # Errors if there are not containers found

    # Reconfigure kubelet to use containerd
    containerdFlags="--container-runtime=remote --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
    sed -i "s@\(KUBELET_KUBEADM_ARGS=\".*\)\"@\1 $containerdFlags\" @" /var/lib/kubelet/kubeadm-flags.env
    systemctl daemon-reload
}
