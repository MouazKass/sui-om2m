#!/bin/sh
# esp_ready.sh - keepalived health check: this Pi may hold the ESP VIP only if
# it can actually serve an ESP: Wi-Fi has an address, the MQTT broker accepts
# connections, and the ESP bridge (om2m-ipe-bridge) is running.
ip -4 addr show dev wlan0 | grep -q 'inet ' || exit 1
timeout 1 bash -c '</dev/tcp/127.0.0.1/1883' 2>/dev/null || exit 1
systemctl is-active --quiet om2m-ipe-bridge || exit 1
exit 0
