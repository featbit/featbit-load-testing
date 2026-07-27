#!/bin/sh
set -eu

if [ -z "${RUN_ID:-}" ] || [ -z "${NODE_NAME:-}" ]; then
    echo "RUN_ID and NODE_NAME are required." >&2
    exit 1
fi

results_dir="/results"
buffer_dir="/buffer"
node_token="$(printf '%s' "$NODE_NAME" | tr -c 'A-Za-z0-9._-' '_')"
samples_name="${RUN_ID}-node-${node_token}-1s.tsv"
metadata_name="${RUN_ID}-node-${node_token}-metadata.txt"
samples_path="${buffer_dir}/${samples_name}"
metadata_path="${buffer_dir}/${metadata_name}"
published_samples_path="${results_dir}/${samples_name}"
published_metadata_path="${results_dir}/${metadata_name}"
els_map_path="/config/els-map"

publish_evidence() {
    cp "$samples_path" "${published_samples_path}.partial"
    mv "${published_samples_path}.partial" "$published_samples_path"
    cp "$metadata_path" "${published_metadata_path}.partial"
    mv "${published_metadata_path}.partial" "$published_metadata_path"
}

finish_collection() {
    publish_evidence
    exit 0
}

trap finish_collection TERM INT

if [ -f "$published_samples_path" ]; then
    cp "$published_samples_path" "$samples_path"
fi
if [ -f "$published_metadata_path" ]; then
    cp "$published_metadata_path" "$metadata_path"
fi

read_psi_total() {
    pressure_path="$1"
    pressure_kind="$2"
    awk -v kind="$pressure_kind" '
        $1 == kind {
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^total=/) {
                    split($i, value, "=")
                    print value[2]
                    exit
                }
            }
        }
    ' "$pressure_path" 2>/dev/null || true
}

read_named_value() {
    source_path="$1"
    value_name="$2"
    awk -v name="$value_name" '$1 == name { print $2; exit }' \
        "$source_path" 2>/dev/null || true
}

sum_softirq() {
    softirq_name="$1"
    awk -v name="${softirq_name}:" '
        $1 == name {
            total = 0
            for (i = 2; i <= NF; i++) {
                total += $i
            }
            printf "%.0f\n", total
            exit
        }
    ' /host/proc/softirqs 2>/dev/null || true
}

read_network_device() {
    interface_name="$1"
    awk -v interface_name="${interface_name}:" '
        $1 == interface_name {
            print $2, $3, $4, $5, $10, $11, $12, $13
            exit
        }
    ' /host/proc/net/dev 2>/dev/null || true
}

read_protocol_value() {
    source_path="$1"
    protocol_name="$2"
    metric_name="$3"
    awk -v protocol="${protocol_name}:" -v metric="$metric_name" '
        $1 == protocol && header_seen == 0 {
            for (i = 2; i <= NF; i++) {
                header[i] = $i
            }
            header_seen = 1
            next
        }
        $1 == protocol && header_seen == 1 {
            for (i = 2; i <= NF; i++) {
                if (header[i] == metric) {
                    print $i
                    exit
                }
            }
        }
    ' "$source_path" 2>/dev/null || true
}

els_cgroups_path="${buffer_dir}/${RUN_ID}-node-${node_token}-els-cgroups.txt"
els_mappings="$(
    awk -F '|' -v node="$NODE_NAME" '$1 == node { print }' \
        "$els_map_path" 2>/dev/null || true
)"
: > "${els_cgroups_path}.partial"
if [ -n "$els_mappings" ]; then
    printf '%s\n' "$els_mappings" |
        while IFS='|' read -r mapping_node mapping_pod mapping_container_id; do
            if [ -z "$mapping_pod" ] || [ -z "$mapping_container_id" ]; then
                continue
            fi
            mapping_container_cgroup="$(
                find /host/sys/fs/cgroup -type d \
                    -name "*${mapping_container_id}*" 2>/dev/null |
                    head -n 1
            )"
            if [ -z "$mapping_container_cgroup" ]; then
                echo \
                    "Could not find the host cgroup for ELS container ${mapping_container_id}." \
                    >&2
                exit 1
            fi

            mapping_limit_cgroup=""
            current_cgroup="$mapping_container_cgroup"
            while [ "$current_cgroup" != "/host/sys/fs/cgroup" ] && \
                [ "$current_cgroup" != "/" ]; do
                if [ -r "${current_cgroup}/cpu.max" ]; then
                    cpu_quota="$(
                        awk '{ print $1 }' "${current_cgroup}/cpu.max"
                    )"
                    if [ -n "$cpu_quota" ] && [ "$cpu_quota" != "max" ]; then
                        mapping_limit_cgroup="$current_cgroup"
                        break
                    fi
                fi
                current_cgroup="$(dirname "$current_cgroup")"
            done
            if [ -z "$mapping_limit_cgroup" ]; then
                echo \
                    "Could not find a finite CPU quota cgroup for ELS Pod ${mapping_pod}." \
                    >&2
                exit 1
            fi
            printf '%s|%s|%s|%s\n' \
                "$mapping_pod" \
                "$mapping_container_id" \
                "$mapping_container_cgroup" \
                "$mapping_limit_cgroup" \
                >> "${els_cgroups_path}.partial"
        done
fi
mv "${els_cgroups_path}.partial" "$els_cgroups_path"

els_pod_count="$(awk 'END { print NR + 0 }' "$els_cgroups_path")"
els_pod="$(
    awk -F '|' '
        {
            if (NR > 1) {
                printf ","
            }
            printf "%s", $1
        }
        END {
            if (NR > 0) {
                printf "\n"
            }
        }
    ' "$els_cgroups_path"
)"
els_container_id="$(
    awk -F '|' '
        {
            if (NR > 1) {
                printf ","
            }
            printf "%s", $2
        }
        END {
            if (NR > 0) {
                printf "\n"
            }
        }
    ' "$els_cgroups_path"
)"
els_container_cgroup_path="$(
    awk -F '|' '
        {
            if (NR > 1) {
                printf ","
            }
            printf "%s", $3
        }
        END {
            if (NR > 0) {
                printf "\n"
            }
        }
    ' "$els_cgroups_path"
)"
els_cpu_limit_cgroup_path="$(
    awk -F '|' '
        {
            if (NR > 1) {
                printf ","
            }
            printf "%s", $4
        }
        END {
            if (NR > 0) {
                printf "\n"
            }
        }
    ' "$els_cgroups_path"
)"

read_els_counters() {
    aggregate_usage=0
    aggregate_periods=0
    aggregate_throttled_periods=0
    aggregate_throttled_usec=0
    aggregate_pressure_usec=0
    if [ ! -s "$els_cgroups_path" ]; then
        printf '%s\n' "-1 -1 -1 -1 -1"
        return
    fi
    while IFS='|' read -r counter_pod counter_id counter_cgroup counter_limit; do
        counter_usage="$(
            read_named_value "${counter_cgroup}/cpu.stat" usage_usec
        )"
        counter_periods="$(
            read_named_value "${counter_limit}/cpu.stat" nr_periods
        )"
        counter_throttled_periods="$(
            read_named_value "${counter_limit}/cpu.stat" nr_throttled
        )"
        counter_throttled_usec="$(
            read_named_value "${counter_limit}/cpu.stat" throttled_usec
        )"
        counter_pressure_usec="$(
            read_psi_total "${counter_limit}/cpu.pressure" some
        )"
        aggregate_usage=$((aggregate_usage + ${counter_usage:-0}))
        aggregate_periods=$((aggregate_periods + ${counter_periods:-0}))
        aggregate_throttled_periods=$((
            aggregate_throttled_periods + ${counter_throttled_periods:-0}
        ))
        aggregate_throttled_usec=$((
            aggregate_throttled_usec + ${counter_throttled_usec:-0}
        ))
        aggregate_pressure_usec=$((
            aggregate_pressure_usec + ${counter_pressure_usec:-0}
        ))
    done < "$els_cgroups_path"
    printf '%s %s %s %s %s\n' \
        "$aggregate_usage" \
        "$aggregate_periods" \
        "$aggregate_throttled_periods" \
        "$aggregate_throttled_usec" \
        "$aggregate_pressure_usec"
}

if [ ! -f "$metadata_path" ]; then
    {
        printf 'run_id=%s\n' "$RUN_ID"
        printf 'node=%s\n' "$NODE_NAME"
        printf 'collector_started_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'kernel=%s\n' "$(uname -r)"
        printf 'cpu_model=%s\n' "$(
            awk -F ':' '/^model name/ {
                sub(/^[[:space:]]+/, "", $2)
                print $2
                exit
            }' /host/proc/cpuinfo
        )"
        printf 'els_pod=%s\n' "$els_pod"
        printf 'els_pod_count=%s\n' "$els_pod_count"
        printf 'els_mapping_mode=all-pods-on-node\n'
        printf 'els_container_id=%s\n' "$els_container_id"
        printf 'els_container_cgroup=%s\n' "$els_container_cgroup_path"
        printf 'els_cpu_limit_cgroup=%s\n' "$els_cpu_limit_cgroup_path"
        if [ -s "$els_cgroups_path" ]; then
            printf 'els_cpu_max=%s\n' "$(
                while IFS='|' read -r metadata_pod metadata_id \
                    metadata_cgroup metadata_limit; do
                    tr '\n' ' ' < "${metadata_limit}/cpu.max"
                    printf ';'
                done < "$els_cgroups_path"
            )"
        fi
        printf 'target_sample_interval_seconds=1\n'
    } > "$metadata_path"
fi

if [ ! -f "$samples_path" ]; then
    printf '%s\n' \
        'observed_at_utc	uptime_seconds	cpu_user	cpu_nice	cpu_system	cpu_idle	cpu_iowait	cpu_irq	cpu_softirq	cpu_steal	procs_running	procs_blocked	load_1m	run_queue	cpu_pressure_some_usec	memory_pressure_some_usec	io_pressure_some_usec	softirq_net_rx	softirq_net_tx	softirq_timer	eth0_rx_bytes	eth0_rx_packets	eth0_rx_errors	eth0_rx_drops	eth0_tx_bytes	eth0_tx_packets	eth0_tx_errors	eth0_tx_drops	cilium_rx_bytes	cilium_rx_packets	cilium_rx_errors	cilium_rx_drops	cilium_tx_bytes	cilium_tx_packets	cilium_tx_errors	cilium_tx_drops	tcp_retrans_segs	tcp_in_errors	tcp_ext_listen_drops	tcp_ext_backlog_drops	tcp_ext_rcv_queue_drops	els_pod	els_cpu_usage_usec	els_cpu_periods	els_cpu_throttled_periods	els_cpu_throttled_usec	els_cpu_pressure_some_usec' \
        > "$samples_path"
fi
publish_evidence

sample_count=0
while :; do
    observed_at_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    uptime_seconds="$(awk '{ print $1 }' /host/proc/uptime)"

    cpu_values="$(awk '/^cpu / {
        print $2, $3, $4, $5, $6, $7, $8, $9
        exit
    }' /host/proc/stat)"
    set -- $cpu_values
    cpu_user="${1:-0}"
    cpu_nice="${2:-0}"
    cpu_system="${3:-0}"
    cpu_idle="${4:-0}"
    cpu_iowait="${5:-0}"
    cpu_irq="${6:-0}"
    cpu_softirq="${7:-0}"
    cpu_steal="${8:-0}"

    procs_running="$(read_named_value /host/proc/stat procs_running)"
    procs_blocked="$(read_named_value /host/proc/stat procs_blocked)"
    load_1m="$(awk '{ print $1 }' /host/proc/loadavg)"
    run_queue="$(awk '{
        split($4, tasks, "/")
        print tasks[1]
    }' /host/proc/loadavg)"

    cpu_pressure_some="$(read_psi_total /host/proc/pressure/cpu some)"
    memory_pressure_some="$(read_psi_total /host/proc/pressure/memory some)"
    io_pressure_some="$(read_psi_total /host/proc/pressure/io some)"
    softirq_net_rx="$(sum_softirq NET_RX)"
    softirq_net_tx="$(sum_softirq NET_TX)"
    softirq_timer="$(sum_softirq TIMER)"

    eth0_values="$(read_network_device eth0)"
    set -- ${eth0_values:-0 0 0 0 0 0 0 0}
    eth0_rx_bytes="${1:-0}"
    eth0_rx_packets="${2:-0}"
    eth0_rx_errors="${3:-0}"
    eth0_rx_drops="${4:-0}"
    eth0_tx_bytes="${5:-0}"
    eth0_tx_packets="${6:-0}"
    eth0_tx_errors="${7:-0}"
    eth0_tx_drops="${8:-0}"

    cilium_values="$(read_network_device cilium_host)"
    set -- ${cilium_values:-0 0 0 0 0 0 0 0}
    cilium_rx_bytes="${1:-0}"
    cilium_rx_packets="${2:-0}"
    cilium_rx_errors="${3:-0}"
    cilium_rx_drops="${4:-0}"
    cilium_tx_bytes="${5:-0}"
    cilium_tx_packets="${6:-0}"
    cilium_tx_errors="${7:-0}"
    cilium_tx_drops="${8:-0}"

    tcp_retrans_segs="$(
        read_protocol_value /host/proc/net/snmp Tcp RetransSegs
    )"
    tcp_in_errors="$(read_protocol_value /host/proc/net/snmp Tcp InErrs)"
    tcp_ext_listen_drops="$(
        read_protocol_value /host/proc/net/netstat TcpExt ListenDrops
    )"
    tcp_ext_backlog_drops="$(
        read_protocol_value /host/proc/net/netstat TcpExt TCPBacklogDrop
    )"
    tcp_ext_rcv_queue_drops="$(
        read_protocol_value /host/proc/net/netstat TcpExt TCPRcvQDrop
    )"

    set -- $(read_els_counters)
    els_cpu_usage="${1:--1}"
    els_cpu_periods="${2:--1}"
    els_cpu_throttled_periods="${3:--1}"
    els_cpu_throttled_usec="${4:--1}"
    els_cpu_pressure_some="${5:--1}"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$observed_at_utc" \
        "$uptime_seconds" \
        "$cpu_user" \
        "$cpu_nice" \
        "$cpu_system" \
        "$cpu_idle" \
        "$cpu_iowait" \
        "$cpu_irq" \
        "$cpu_softirq" \
        "$cpu_steal" \
        "${procs_running:-0}" \
        "${procs_blocked:-0}" \
        "$load_1m" \
        "$run_queue" \
        "${cpu_pressure_some:-0}" \
        "${memory_pressure_some:-0}" \
        "${io_pressure_some:-0}" \
        "${softirq_net_rx:-0}" \
        "${softirq_net_tx:-0}" \
        "${softirq_timer:-0}" \
        "$eth0_rx_bytes" \
        "$eth0_rx_packets" \
        "$eth0_rx_errors" \
        "$eth0_rx_drops" \
        "$eth0_tx_bytes" \
        "$eth0_tx_packets" \
        "$eth0_tx_errors" \
        "$eth0_tx_drops" \
        "$cilium_rx_bytes" \
        "$cilium_rx_packets" \
        "$cilium_rx_errors" \
        "$cilium_rx_drops" \
        "$cilium_tx_bytes" \
        "$cilium_tx_packets" \
        "$cilium_tx_errors" \
        "$cilium_tx_drops" \
        "${tcp_retrans_segs:-0}" \
        "${tcp_in_errors:-0}" \
        "${tcp_ext_listen_drops:-0}" \
        "${tcp_ext_backlog_drops:-0}" \
        "${tcp_ext_rcv_queue_drops:-0}" \
        "$els_pod" \
        "${els_cpu_usage:-1}" \
        "${els_cpu_periods:-1}" \
        "${els_cpu_throttled_periods:-1}" \
        "${els_cpu_throttled_usec:-1}" \
        "${els_cpu_pressure_some:-1}" \
        >> "$samples_path"

    sample_count=$((sample_count + 1))
    if [ $((sample_count % 30)) -eq 0 ]; then
        publish_evidence
    fi
    sample_finished_uptime="$(awk '{ print $1 }' /host/proc/uptime)"
    sleep_seconds="$(
        awk \
            -v started="$uptime_seconds" \
            -v finished="$sample_finished_uptime" \
            'BEGIN {
                remaining = 1.0 - (finished - started)
                if (remaining > 0.001) {
                    printf "%.3f\n", remaining
                } else {
                    print "0"
                }
            }'
    )"
    if [ "$sleep_seconds" != "0" ]; then
        sleep "$sleep_seconds"
    fi
done
