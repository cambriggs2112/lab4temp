#!/usr/bin/env bash
# assets/entrypoint.d/10-ros-ip.sh
# Setup by Braden Meyers to fix Hostname resolution on lab machine Aug 2026
#
# Advertise this machine to the ROS master by IP address instead of by hostname.
#
# Under --net=host, dt-ros-commons/assets/entrypoint.d/ros.sh sets
#     ROS_HOSTNAME="$(hostname).local"
# That is correct only if the host's mDNS name really resolves from the robot.
# On lab machines it often does not: avahi may publish a name that disagrees
# with /etc/hostname, and on a dual-homed host the name can resolve to a NIC
# the robot cannot route to. Either way the master hands peers an unreachable
# URI, registration succeeds, and topics silently never connect.
#
# This derives the local address the kernel would actually use to reach the
# master, and pins both ROS_HOSTNAME and ROS_IP to it. No hardcoded IPs or
# interface names, so it is correct in every lab and on every host.
#
# ROS_HOSTNAME takes precedence over ROS_IP in ROS 1, so setting ROS_IP alone
# is not enough -- ROS_HOSTNAME must be overwritten too. Setting both also
# makes this hook order-independent: if ros.sh happens to run afterwards, it
# sees both as externally "forced" and leaves them alone.

_dt_configure_ros_ip() {
    local auto_hostname="$(hostname).local"

    # A ROS_HOSTNAME that is NOT the value ros.sh derives is a deliberate
    # choice by the user or the lab. Respect it and change nothing.
    if [ -n "${ROS_HOSTNAME:-}" ] && [ "${ROS_HOSTNAME}" != "${auto_hostname}" ]; then
        info "ROS_HOSTNAME externally set to '${ROS_HOSTNAME}'; leaving networking alone."
        return 0
    fi

    # An explicitly provided ROS_IP wins; mirror it into ROS_HOSTNAME so that
    # ros.sh cannot override it with the (possibly unresolvable) .local name.
    if [ -n "${ROS_IP:-}" ]; then
        export ROS_HOSTNAME="${ROS_IP}"
        info "ROS_IP externally set to '${ROS_IP}'; pinned ROS_HOSTNAME to match."
        return 0
    fi

    local master_host=""
    if [ -n "${ROS_MASTER_URI:-}" ]; then
        master_host="$(printf '%s' "${ROS_MASTER_URI}" \
            | sed -nE 's#^[a-zA-Z]+://\[?([^]:/]+)\]?.*#\1#p')"
    fi
    if [ -z "${master_host}" ] && [ -n "${VEHICLE_NAME:-}" ]; then
        master_host="${VEHICLE_NAME}.local"
    fi
    if [ -z "${master_host}" ]; then
        warning "No ROS master known; leaving ROS_HOSTNAME='${ROS_HOSTNAME:-unset}'."
        return 0
    fi

    local src_ip
    src_ip="$(python3 -c '
import socket, sys
host = sys.argv[1]
try:
    ip = socket.getaddrinfo(host, None, socket.AF_INET)[0][4][0]
except Exception:
    sys.exit(1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect((ip, 11311))          # no packets sent; just consults the route table
    src = s.getsockname()[0]
finally:
    s.close()
if src.startswith("127."):          # local-only master: leave ROS alone
    sys.exit(1)
print(src)
' "${master_host}" 2>/dev/null)"

    if [ -n "${src_ip}" ]; then
        export ROS_IP="${src_ip}"
        export ROS_HOSTNAME="${src_ip}"
        info "ROS_IP/ROS_HOSTNAME=${src_ip} (route to ROS master '${master_host}')"
    else
        warning "Could not resolve ROS master '${master_host}'; leaving ROS_HOSTNAME='${ROS_HOSTNAME:-unset}'."
    fi
    return 0
}

_dt_configure_ros_ip || true
unset -f _dt_configure_ros_ip
