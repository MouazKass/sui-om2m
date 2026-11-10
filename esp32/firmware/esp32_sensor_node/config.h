// ============================================================================
//  config.h - per-device settings. Edit this file before flashing each ESP32.
//  Every ESP32 needs its OWN DEVICE_ID (it becomes the AE name in OM2M and the
//  on-chain resource id /in-cse/C<DEVICE_ID>).
//
//  Every #define is guarded with #ifndef so the host build
//  (sim/firmware_hostcheck) can shorten the timings.
// ============================================================================
#pragma once

// ---- WiFi --------------------------------------------------------------------
// The ESP32 must join a 2.4 GHz network that can reach the Raspberry Pis.
#ifndef WIFI_SSID
#define WIFI_SSID        "YOUR_WIFI_NAME"
#endif
#ifndef WIFI_PASS
#define WIFI_PASS        "YOUR_WIFI_PASSWORD"
#endif

// ---- The cluster ---------------------------------------------------------------
// The sensor belongs to the CLUSTER, not to one Pi. CLUSTER_SEEDS is only the
// starting list: at run time the sensor also learns members from the retained
// topic om2m/cluster/brokers, so nodes added later are used without a reflash.
// Format: label=host:port, comma-separated, at most 8.
#ifndef CLUSTER_SEEDS
#define CLUSTER_SEEDS "rpi1=10.25.96.200:1883,rpi2=10.25.96.201:1883,rpi3=10.25.96.203:1883," \
                      "rpi4=10.25.96.204:1883,rpi5=10.25.96.205:1883"
#endif
// Preferred broker. Used whenever it is healthy; the sensor returns to it
// after an outage once it has been reachable for HOME_STABLE_MS.
#ifndef HOME_NODE
#define HOME_NODE "rpi2"
#endif
// A broker learned at run time is accepted only if its host starts with this
// (the testbed subnet). The brokers are anonymous, so this bounds where a
// forged membership message could send the sensor. "" disables the check.
#ifndef CLUSTER_ALLOW_PREFIX
#define CLUSTER_ALLOW_PREFIX "10.25.96."
#endif

// Leave both empty ("") if the brokers allow anonymous clients.
#ifndef MQTT_USER
#define MQTT_USER        ""
#endif
#ifndef MQTT_PASS
#define MQTT_PASS        ""
#endif

// ---- Identity ----------------------------------------------------------------
// Lowercase letters, digits and '-' only. Must be unique across the testbed.
#ifndef DEVICE_ID
#define DEVICE_ID        "esp32-dht-01"
#endif
#define FW_VERSION       "2.1.0"

// ---- Sensors (set to 0 to disable one) ----------------------------------------
#ifndef ENABLE_DHT
#define ENABLE_DHT       1
#endif
#define DHT_PIN          4        // DHT11 data pin -> GPIO 4
#define DHT_TYPE         DHT11

#ifndef ENABLE_LDR
#define ENABLE_LDR       1
#endif
#define LDR_PIN          34       // LDR voltage divider -> GPIO 34 (ADC1, input-only)

#define STATUS_LED_PIN   2        // on-board LED on most ESP32 DevKit boards

// ---- Timing --------------------------------------------------------------------
#ifndef PUBLISH_INTERVAL_MS
#define PUBLISH_INTERVAL_MS   5000UL   // DHT11 needs >= 1 s between reads
#endif
#ifndef WIFI_RESTART_AFTER_MS
#define WIFI_RESTART_AFTER_MS 60000UL  // reboot if WiFi stays down this long
#endif
// Failure detection: PubSubClient drops a silent broker after 1-2 keep-alives,
// so 4 s gives detection in 4-8 s; each dead candidate then costs at most
// CONNECT_TIMEOUT_MS. Together: re-attached within ~10 s of a broker dying.
#ifndef MQTT_KEEPALIVE_S
#define MQTT_KEEPALIVE_S      4
#endif
#ifndef CONNECT_TIMEOUT_MS
#define CONNECT_TIMEOUT_MS    1500
#endif
#ifndef BACKOFF_BASE_MS
#define BACKOFF_BASE_MS       1000UL   // per-broker backoff after a failure ...
#endif
#ifndef BACKOFF_MAX_MS
#define BACKOFF_MAX_MS        60000UL  // ... doubling, capped here
#endif
#ifndef HOME_PROBE_MS
#define HOME_PROBE_MS         30000UL  // while away, probe home this often
#endif
#ifndef HOME_STABLE_MS
#define HOME_STABLE_MS        120000UL // home must answer every probe this long
#endif
// Readings not yet acknowledged by a bridge are kept and re-sent after a
// failover (the bridges drop duplicates). 64 x 5 s = 5 min of readings.
#ifndef RESEND_SLOTS
#define RESEND_SLOTS          64
#endif
#ifndef ACK_WAIT_MS
#define ACK_WAIT_MS           1500UL   // after connecting, wait this long for an ack
#endif
// A broker that is up but whose bridge is not (nothing is acknowledged) would
// swallow readings. If readings were published but none acknowledged for this
// long, the broker is treated as failed and the sensor fails over.
#ifndef NO_ACK_FAILOVER_MS
#define NO_ACK_FAILOVER_MS    20000UL
#endif

// ---- Time (optional) -----------------------------------------------------------
// If the network has no internet, NTP fails and the ESP32 sends ts=0;
// the Pi bridge then stamps the reading with its own receive time.
#ifndef NTP_SERVER
#define NTP_SERVER       "pool.ntp.org"
#endif
