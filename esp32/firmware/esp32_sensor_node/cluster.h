// ============================================================================
//  cluster.h - broker selection for a sensor that belongs to the CLUSTER,
//  not to one Raspberry Pi.
//
//  Pure C++ (no Arduino calls), so the exact same logic is unit-tested on a PC
//  (sim/firmware_hostcheck/cluster_test.cpp) and mirrored by the Python
//  simulator (sim/esp32_sim.py, class Selector). Both run the shared vectors in
//  sim/selector_vectors.txt, so the firmware and the simulator cannot drift.
//
//  Rules (DESIGN.md section 3):
//   * Candidates are tried home first, then the others in list order, wrapping.
//     Brokers the cluster reports as down (alive=0) are tried only after every
//     broker reported up has been tried.
//   * A broker that fails (connect refused / timed out / connection lost) is
//     skipped for a growing, bounded backoff: base * 2^(failures-1), capped.
//     The selector moves straight on to the next candidate, so a sensor
//     re-attaches as soon as it has detected the loss.
//   * Return home with hysteresis: while on another broker, home is probed
//     every homeProbeMs; the sensor moves back only after home has answered
//     every probe for homeStableMs. One failed probe restarts the window.
//     This stops a flapping home broker from dragging the sensor back and
//     forth.
//   * Membership is learned at run time from the retained topic
//     om2m/cluster/brokers that every Pi's bridge publishes, so a node added
//     later is used without reflashing. Seeds from config.h are never removed;
//     a learned host must start with the configured allow prefix.
// ============================================================================
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace cluster {

static const int MAX_BROKERS = 8;
static const int LABEL_LEN = 16;
static const int HOST_LEN = 40;

struct Broker {
  char label[LABEL_LEN];
  char host[HOST_LEN];
  uint16_t port;
  bool alive;          // last state reported by the cluster (seeds start alive)
  bool seed;           // from config.h: never removed
  uint32_t failures;   // consecutive failures
  unsigned long retryAtMs;
};

struct Params {
  unsigned long backoffBaseMs = 1000;
  unsigned long backoffMaxMs = 60000;
  unsigned long homeProbeMs = 30000;
  unsigned long homeStableMs = 120000;
};

static inline bool validLabel(const char* s) {
  size_t n = strlen(s);
  if (n == 0 || n >= (size_t)LABEL_LEN) return false;
  for (size_t i = 0; i < n; i++) {
    char c = s[i];
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
  }
  return true;
}

static inline bool validHost(const char* s) {
  size_t n = strlen(s);
  if (n == 0 || n >= (size_t)HOST_LEN) return false;
  for (size_t i = 0; i < n; i++) {
    char c = s[i];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
          c == '.' || c == '-')) return false;
  }
  return true;
}

class Selector {
 public:
  Broker b[MAX_BROKERS];
  int n = 0;
  int home = -1;
  int current = -1;      // index connected to, -1 when not connected
  Params p;

  // home-return hysteresis
  unsigned long lastProbeMs = 0;
  unsigned long homeOkSinceMs = 0;
  bool homeOk = false;

  int find(const char* label) const {
    for (int i = 0; i < n; i++) if (strcmp(b[i].label, label) == 0) return i;
    return -1;
  }

  // Adds or updates a broker. Returns its index, or -1 if invalid / full.
  int add(const char* label, const char* host, uint16_t port, bool seed) {
    if (!validLabel(label) || !validHost(host) || port == 0) return -1;
    int i = find(label);
    if (i < 0) {
      if (n >= MAX_BROKERS) return -1;
      i = n++;
      memset(&b[i], 0, sizeof(Broker));
      strncpy(b[i].label, label, LABEL_LEN - 1);
      b[i].alive = true;
      b[i].seed = seed;
    }
    if (strcmp(b[i].host, host) != 0 || b[i].port != port) {
      strncpy(b[i].host, host, HOST_LEN - 1);
      b[i].host[HOST_LEN - 1] = 0;
      b[i].port = port;
      b[i].failures = 0;
      b[i].retryAtMs = 0;
    }
    b[i].seed = b[i].seed || seed;
    return i;
  }

  // "rpi1=10.25.96.200:1883,rpi2=10.25.96.201:1883"  -> seeds
  int addSeeds(const char* list) {
    int added = 0;
    parseEntries(list, true, "", &added);
    return added;
  }

  bool setHome(const char* label) {
    home = find(label);
    return home >= 0;
  }

  // Next broker to try, or -1 if every broker is backing off.
  int next(unsigned long now) const {
    if (n == 0) return -1;
    int start = home >= 0 ? home : 0;
    for (int pass = 0; pass < 2; pass++) {
      for (int k = 0; k < n; k++) {
        int i = (start + k) % n;
        if (pass == 0 && !b[i].alive) continue;
        if (pass == 1 && b[i].alive) continue;
        if (b[i].retryAtMs > now) continue;
        return i;
      }
    }
    return -1;
  }

  // Milliseconds until some broker leaves backoff (0 if one is ready now).
  unsigned long waitMs(unsigned long now) const {
    unsigned long best = 0xFFFFFFFFUL;
    for (int i = 0; i < n; i++) {
      if (b[i].retryAtMs <= now) return 0;
      unsigned long d = b[i].retryAtMs - now;
      if (d < best) best = d;
    }
    return n ? best : 1000;
  }

  void onConnected(int i, unsigned long now) {
    if (i < 0 || i >= n) return;
    current = i;
    b[i].failures = 0;
    b[i].retryAtMs = 0;
    lastProbeMs = now;
    homeOk = false;
    homeOkSinceMs = 0;
  }

  void onFailed(int i, unsigned long now) {
    if (i < 0 || i >= n) return;
    if (current == i) current = -1;
    if (b[i].failures < 16) b[i].failures++;
    unsigned long backoff = p.backoffBaseMs;
    for (uint32_t k = 1; k < b[i].failures && backoff < p.backoffMaxMs; k++) backoff *= 2;
    if (backoff > p.backoffMaxMs) backoff = p.backoffMaxMs;
    b[i].retryAtMs = now + backoff;
    if (i == home) { homeOk = false; homeOkSinceMs = 0; }
  }

  // A broker that accepts connections but swallows readings (its bridge is
  // down): fail it and keep it out for at least `ms`, beyond normal backoff.
  void penalize(int i, unsigned long now, unsigned long ms) {
    onFailed(i, now);
    if (i >= 0 && i < n && b[i].retryAtMs < now + ms) b[i].retryAtMs = now + ms;
  }

  void onDisconnectedCleanly() { current = -1; }

  bool onHome() const { return current >= 0 && current == home; }

  bool probeDue(unsigned long now) const {
    return current >= 0 && home >= 0 && current != home && now - lastProbeMs >= p.homeProbeMs;
  }

  void onHomeProbe(bool ok, unsigned long now) {
    lastProbeMs = now;
    if (!ok || (home >= 0 && (!b[home].alive || b[home].retryAtMs > now))) {
      homeOk = false; homeOkSinceMs = 0; return;
    }
    if (!homeOk) { homeOk = true; homeOkSinceMs = now; }
  }

  bool shouldReturnHome(unsigned long now) const {
    return current >= 0 && home >= 0 && current != home && homeOk &&
           b[home].retryAtMs <= now && now - homeOkSinceMs >= p.homeStableMs;
  }

  // Retained om2m/cluster/brokers payload:
  //   v1;<ts>;rpi1=10.25.96.200:1883:1,rpi2=10.25.96.201:1883:0,...
  // Returns the number of entries accepted, or -1 if the payload is malformed.
  int learn(const char* payload, const char* allowPrefix) {
    if (strncmp(payload, "v1;", 3) != 0) return -1;
    const char* p2 = strchr(payload + 3, ';');
    if (!p2) return -1;
    int accepted = 0;
    // learned (non-seed) brokers missing from this list are marked down
    bool listed[MAX_BROKERS] = {false};
    if (!parseEntries(p2 + 1, false, allowPrefix, &accepted, listed)) return -1;
    for (int i = 0; i < n; i++) if (!listed[i] && !b[i].seed) b[i].alive = false;
    return accepted;
  }

 private:
  bool parseEntries(const char* list, bool seed, const char* allowPrefix, int* accepted,
                    bool* listed = nullptr) {
    char buf[512];
    if (strlen(list) >= sizeof(buf)) return false;
    strcpy(buf, list);
    char* save = nullptr;
    for (char* tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(nullptr, ",", &save)) {
      char* eq = strchr(tok, '=');
      if (!eq) continue;
      *eq = 0;
      const char* label = tok;
      char* host = eq + 1;
      char* c1 = strchr(host, ':');
      if (!c1) continue;
      *c1 = 0;
      char* portStr = c1 + 1;
      int alive = 1;
      char* c2 = strchr(portStr, ':');
      if (c2) { *c2 = 0; alive = atoi(c2 + 1) ? 1 : 0; }
      long port = strtol(portStr, nullptr, 10);
      if (port <= 0 || port > 65535) continue;
      if (!seed && allowPrefix && *allowPrefix &&
          strncmp(host, allowPrefix, strlen(allowPrefix)) != 0) continue;
      int i = add(label, host, (uint16_t)port, seed);
      if (i < 0) continue;
      if (!seed) b[i].alive = alive != 0;
      if (listed) listed[i] = true;
      (*accepted)++;
    }
    return true;
  }
};

// Session ids order connections across brokers: "<epoch>.<n>".
// Returns <0, 0, >0 like strcmp. Malformed ids sort lowest.
static inline int compareSession(const char* a, const char* b2) {
  unsigned long ea = 0, na = 0, eb = 0, nb = 0;
  int ra = sscanf(a, "%lu.%lu", &ea, &na);
  int rb = sscanf(b2, "%lu.%lu", &eb, &nb);
  if (ra != 2 && rb != 2) return 0;
  if (ra != 2) return -1;
  if (rb != 2) return 1;
  if (ea != eb) return ea < eb ? -1 : 1;
  if (na != nb) return na < nb ? -1 : 1;
  return 0;
}

}  // namespace cluster
