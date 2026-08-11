#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd -- "${script_dir}/../.." && pwd)"
readonly compose_file="${script_dir}/compose.yaml"
readonly state_dir="${SCOUT_TEST_STATE_DIR:-/tmp/nico-scout-customization-test}"
readonly interface_state="${state_dir}/interface.env"
readonly cert_dir="${state_dir}/certs"
readonly scout_address=172.30.0.10
readonly marker=NICO_SCOUT_CUSTOMIZATION_E2E_PASS

usage() {
    echo "usage: $0 {build|run|status|restore}" >&2
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "required command not found: $1" >&2
        exit 1
    fi
}

api_pod() {
    kubectl --namespace nico-system get pods \
        --selector app.kubernetes.io/name=nico-api,app.kubernetes.io/component=api \
        --field-selector status.phase=Running \
        --output jsonpath='{.items[0].metadata.name}'
}

admin_cli() {
    local pod
    pod="$(api_pod)"
    if [[ -z "${pod}" ]]; then
        echo "nico-api has no running pod" >&2
        return 1
    fi
    kubectl --namespace nico-system exec "${pod}" -- env \
        API_URL=https://nico-api.nico-system.svc.cluster.local:1079 \
        ROOT_CA_PATH=/var/run/secrets/spiffe.io/ca.crt \
        CLIENT_CERT_PATH=/var/run/secrets/spiffe.io/tls.crt \
        CLIENT_KEY_PATH=/var/run/secrets/spiffe.io/tls.key \
        /opt/carbide/nico-admin-cli "$@"
}

load_interface_state() {
    if [[ ! -f "${interface_state}" ]]; then
        echo "test interface state not found: ${interface_state}" >&2
        return 1
    fi
    # shellcheck disable=SC1090
    source "${interface_state}"
    export SCOUT_TEST_INTERFACE_ID SCOUT_TEST_MAC_ADDRESS SCOUT_TEST_CERT_DIR="${cert_dir}"
}

compose() {
    docker compose --file "${compose_file}" "$@"
}

build_artifacts() {
    require_command cargo
    require_command docker
    (
        cd "${repo_root}"
        mkdir -p "${state_dir}/cargo-home"
        cargo make build-pxe-build-container
        PXE_DOCKER_CARGO_HOME="${state_dir}/cargo-home" cargo make pxe-docker-scout-x86
    )
}

prepare_tilt() {
    require_command tilt
    require_command kubectl

    if ! tilt get uiresource nico-api >/dev/null 2>&1; then
        echo "Tilt is not running; start it with:" >&2
        echo "  tilt up -f dev/deployment/tilt/Tiltfile" >&2
        exit 1
    fi

    (
        cd "${repo_root}"
        tilt args -- --rest=false --mcp=false --scout-customization=true
        tilt trigger nico-api
        tilt wait --for=condition=Ready --timeout=15m uiresource/nico-api
    )
    kubectl --namespace nico-system rollout status deployment/nico-api --timeout=5m

    if ! kubectl --namespace nico-system get configmap nico-api-site-config-files \
        --output jsonpath='{.data.nico-api-site-config\.toml}' | grep --fixed-strings --quiet "${marker}"; then
        echo "nico-api does not contain the Scout customization fixture" >&2
        exit 1
    fi

    local certificate_ready=false
    local certificate_attempt
    for ((certificate_attempt = 0; certificate_attempt < 60; certificate_attempt++)); do
        if openssl s_client \
            -connect 127.0.0.1:1079 \
            -servername host.docker.internal </dev/null 2>/dev/null \
            | openssl x509 -noout -text 2>/dev/null \
            | grep --fixed-strings --quiet 'DNS:host.docker.internal'; then
            certificate_ready=true
            break
        fi
        sleep 2
    done
    if [[ "${certificate_ready}" != true ]]; then
        echo "nico-api certificate does not include host.docker.internal" >&2
        exit 1
    fi
}

select_interface() {
    local interfaces selected
    interfaces="$(admin_cli --format json machine-interfaces show)"
    selected="$(jq --raw-output '
        .interfaces[]
        | select(.machine_id | startswith("fm100ht"))
        | select((.is_bmc // false) == false)
        | select(.primary_interface == false)
        | select((.address // []) | length == 0)
        | [.id, .mac_address]
        | @tsv
    ' <<<"${interfaces}" | head -n 1)"

    if [[ -z "${selected}" ]]; then
        echo "no unused secondary machine-a-tron host interface is available" >&2
        exit 1
    fi

    IFS=$'\t' read -r SCOUT_TEST_INTERFACE_ID SCOUT_TEST_MAC_ADDRESS <<<"${selected}"
    export SCOUT_TEST_INTERFACE_ID SCOUT_TEST_MAC_ADDRESS
    mkdir -p "${state_dir}"
    printf 'SCOUT_TEST_INTERFACE_ID=%q\nSCOUT_TEST_MAC_ADDRESS=%q\n' \
        "${SCOUT_TEST_INTERFACE_ID}" "${SCOUT_TEST_MAC_ADDRESS}" >"${interface_state}"

    admin_cli machine-interfaces assign-address \
        "${SCOUT_TEST_INTERFACE_ID}" "${scout_address}"
}

create_pxe_client_certificate() {
    mkdir -p "${cert_dir}"
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "${cert_dir}/tls.key" \
        -out "${cert_dir}/tls.csr" \
        -subj /CN=nico-pxe >/dev/null 2>&1
    printf '%s\n' \
        'subjectAltName=URI:spiffe://nico.local/nico-system/sa/nico-pxe' \
        'extendedKeyUsage=clientAuth' >"${cert_dir}/client.ext"
    openssl x509 -req \
        -in "${cert_dir}/tls.csr" \
        -CA "${repo_root}/dev/certs/localhost/ca.crt" \
        -CAkey "${repo_root}/dev/certs/localhost/ca.key" \
        -set_serial 0x4e49434f505845 \
        -days 2 \
        -extfile "${cert_dir}/client.ext" \
        -out "${cert_dir}/tls.crt" >/dev/null 2>&1
    cp "${repo_root}/dev/certs/localhost/ca.crt" "${cert_dir}/ca.crt"
    chmod 0600 "${cert_dir}/tls.key"
    export SCOUT_TEST_CERT_DIR="${cert_dir}"
}

find_power_action() {
    local systems member document
    systems="$(curl --insecure --fail --silent --show-error \
        https://127.0.0.1:12660/redfish/v1/Systems)"
    while IFS= read -r member; do
        document="$(curl --insecure --fail --silent --show-error \
            "https://127.0.0.1:12660${member}")"
        if jq --exit-status 'has("PowerState")' <<<"${document}" >/dev/null; then
            jq --raw-output '.Actions["#ComputerSystem.Reset"].target' <<<"${document}"
            return 0
        fi
    done < <(jq --raw-output '.Members[]."@odata.id"' <<<"${systems}")
    echo "bmc-mock did not expose a controllable ComputerSystem" >&2
    return 1
}

power_on() {
    local action
    action="$(find_power_action)"
    curl --insecure --fail --silent --show-error \
        --request POST \
        --header 'Content-Type: application/json' \
        --data '{"ResetType":"On"}' \
        "https://127.0.0.1:12660${action}" >/dev/null
}

wait_for_marker() {
    local deadline output
    deadline=$((SECONDS + 900))
    while ((SECONDS < deadline)); do
        output="$(docker exec nico-scout-customization-test sshpass -p password ssh \
            -o ConnectTimeout=5 \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            root@172.30.0.10 \
            cat /run/nico-scout-customization-e2e/passed 2>/dev/null || true)"
        if [[ "${output}" == "${marker}" ]]; then
            return 0
        fi
        sleep 5
    done

    echo "timed out waiting for the Scout customization marker" >&2
    compose logs --no-color --tail=100 >&2 || true
    docker exec nico-scout-customization-test \
        tail -n 200 /var/log/nico-scout-test/serial.log >&2 || true
    return 1
}

run_test() {
    for command in curl docker jq kubectl openssl tilt; do
        require_command "${command}"
    done
    for artifact in \
        "${repo_root}/pxe/static/blobs/internal/x86_64/scout.efi" \
        "${repo_root}/pxe/static/blobs/internal/x86_64/scout.squashfs"; do
        if [[ ! -s "${artifact}" ]]; then
            echo "Scout artifact is missing: ${artifact}" >&2
            echo "Build it first with: $0 build" >&2
            exit 1
        fi
    done

    if [[ -f "${interface_state}" ]]; then
        echo "a previous test assignment is still recorded; run '$0 restore' first" >&2
        exit 1
    fi

    prepare_tilt
    select_interface
    create_pxe_client_certificate

    if ! compose up --detach --build; then
        echo "Scout lab failed to start; restoring the API address assignment" >&2
        restore_test
        exit 1
    fi

    local container_status deadline
    deadline=$((SECONDS + 300))
    while ((SECONDS < deadline)); do
        container_status="$(docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
            nico-scout-customization-test 2>/dev/null || true)"
        if [[ "${container_status}" == healthy ]]; then
            break
        fi
        if [[ "${container_status}" == exited || "${container_status}" == dead ]]; then
            compose logs --no-color >&2 || true
            restore_test
            exit 1
        fi
        sleep 5
    done
    if [[ "${container_status:-}" != healthy ]]; then
        echo "Scout lab did not become healthy" >&2
        compose logs --no-color >&2 || true
        restore_test
        exit 1
    fi

    power_on
    wait_for_marker
    echo "PASS: ${marker}"
    echo "Scout remains online; use '$0 status' or the README inspection command"
    echo "Clean up with: $0 restore"
}

status_test() {
    load_interface_state
    compose ps
    docker exec nico-scout-customization-test \
        virsh --connect qemu:///system domstate nico-scout-test || true
    docker exec nico-scout-customization-test \
        tail -n 100 /var/log/nico-scout-test/serial.log || true
}

restore_test() {
    if [[ -f "${interface_state}" ]]; then
        load_interface_state
        compose down --remove-orphans || true
        admin_cli machine-interfaces remove-address \
            "${SCOUT_TEST_INTERFACE_ID}" "${scout_address}" || true
        rm -f "${interface_state}"
    else
        SCOUT_TEST_INTERFACE_ID=unused \
        SCOUT_TEST_MAC_ADDRESS=02:00:00:00:00:10 \
        SCOUT_TEST_CERT_DIR="${cert_dir}" \
            compose down --remove-orphans || true
    fi
}

case "${1:-}" in
    build)
        build_artifacts
        ;;
    run)
        run_test
        ;;
    status)
        status_test
        ;;
    restore)
        restore_test
        ;;
    *)
        usage
        exit 2
        ;;
esac
