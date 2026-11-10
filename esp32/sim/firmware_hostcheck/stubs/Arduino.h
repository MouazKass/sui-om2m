// Host-side stand-in for the Arduino core, ONLY for compile/logic checks of the
// firmware on a PC. Not used on the real ESP32.
#pragma once
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <cstdarg>
#include <string>
#include <ctime>
using std::isnan;
typedef bool boolean;
typedef uint8_t byte;
#define HIGH 1
#define LOW 0
#define OUTPUT 1
#define INPUT 0
extern unsigned long g_virtual_ms;
inline unsigned long millis() { return g_virtual_ms; }
inline void delay(unsigned long ms) { g_virtual_ms += ms; }
inline void pinMode(int, int) {}
inline void digitalWrite(int, int) {}
inline void analogReadResolution(int) {}
inline int analogRead(int) { return 1000 + (int)(g_virtual_ms / 100 % 2000); }
inline uint32_t esp_random() { return 0xA1B2C3D4u; }
struct HostSerial {
  void begin(int) {}
  void print(const char* s) { fprintf(stderr, "%s", s); }
  void println(const char* s) { fprintf(stderr, "%s\n", s); }
  void printf(const char* f, ...) { va_list a; va_start(a, f); vfprintf(stderr, f, a); va_end(a); }
};
extern HostSerial Serial;
struct HostESP { void restart() { fprintf(stderr, "[host] ESP.restart()\n"); } };
extern HostESP ESP;
inline void configTime(long, int, const char*) {}
