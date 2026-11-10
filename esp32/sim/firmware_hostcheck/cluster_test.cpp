// Runs sim/selector_vectors.txt against the firmware's cluster.h.
//   g++ -std=c++17 -Wall -o /tmp/cluster_test cluster_test.cpp && /tmp/cluster_test ../selector_vectors.txt
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include "../../firmware/esp32_sensor_node/cluster.h"

int main(int argc, char** argv) {
  const char* path = argc > 1 ? argv[1] : "../selector_vectors.txt";
  std::ifstream in(path);
  if (!in) { fprintf(stderr, "cannot open %s\n", path); return 2; }
  cluster::Selector s;
  std::string line;
  int lineNo = 0, checks = 0, fails = 0;
  auto expect = [&](bool ok, const std::string& got) {
    checks++;
    if (!ok) { fails++; fprintf(stderr, "FAIL line %d: %s  (got %s)\n", lineNo, line.c_str(), got.c_str()); }
  };
  while (std::getline(in, line)) {
    lineNo++;
    if (line.empty() || line[0] == '#') continue;
    std::istringstream ss(line);
    std::string cmd; ss >> cmd;
    std::string arrow, want;
    auto label = [&](int i) { return i < 0 ? std::string("none") : std::string(s.b[i].label); };
    if (cmd == "params") { ss >> s.p.backoffBaseMs >> s.p.backoffMaxMs >> s.p.homeProbeMs >> s.p.homeStableMs; }
    else if (cmd == "seeds") { std::string l; ss >> l; s.addSeeds(l.c_str()); }
    else if (cmd == "home") { std::string l; ss >> l; s.setHome(l.c_str()); }
    else if (cmd == "next") { unsigned long t; ss >> t >> arrow >> want; std::string g = label(s.next(t)); expect(g == want, g); }
    else if (cmd == "fail") { std::string l; unsigned long t; ss >> l >> t; s.onFailed(s.find(l.c_str()), t); }
    else if (cmd == "penalize") { std::string l; unsigned long t, ms; ss >> l >> t >> ms; s.penalize(s.find(l.c_str()), t, ms); }
    else if (cmd == "ok") { std::string l; unsigned long t; ss >> l >> t; s.onConnected(s.find(l.c_str()), t); }
    else if (cmd == "probe") { int ok; unsigned long t; ss >> ok >> t; s.onHomeProbe(ok != 0, t); }
    else if (cmd == "return") { unsigned long t; ss >> t >> arrow >> want; std::string g = s.shouldReturnHome(t) ? "1" : "0"; expect(g == want, g); }
    else if (cmd == "wait") { unsigned long t; ss >> t >> arrow >> want; std::string g = std::to_string(s.waitMs(t)); expect(g == want, g); }
    else if (cmd == "learn") {
      std::string prefix, payload; ss >> prefix >> payload >> arrow >> want;
      int r = s.learn(payload.c_str(), prefix == "-" ? "" : prefix.c_str());
      expect(std::to_string(r) == want, std::to_string(r));
    }
    else if (cmd == "has") { std::string l; ss >> l >> arrow >> want; std::string g = s.find(l.c_str()) >= 0 ? "1" : "0"; expect(g == want, g); }
    else if (cmd == "alive") { std::string l; ss >> l >> arrow >> want; int i = s.find(l.c_str()); std::string g = (i >= 0 && s.b[i].alive) ? "1" : "0"; expect(g == want, g); }
    else if (cmd == "session") { std::string a, b; ss >> a >> b >> arrow >> want; int c = cluster::compareSession(a.c_str(), b.c_str()); std::string g = std::to_string(c < 0 ? -1 : (c > 0 ? 1 : 0)); expect(g == want, g); }
    else { fprintf(stderr, "unknown command line %d: %s\n", lineNo, line.c_str()); return 2; }
  }
  printf("cluster.h vectors: %d/%d passed\n", checks - fails, checks);
  return fails ? 1 : 0;
}
