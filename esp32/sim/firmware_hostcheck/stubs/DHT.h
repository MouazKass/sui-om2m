#pragma once
#include "Arduino.h"
#define DHT11 11
struct DHT {
  int calls = 0;
  DHT(int, int) {}
  void begin() {}
  // every 4th read fails (NAN) to exercise the retry path
  float readTemperature() { return (++calls % 4 == 0) ? NAN : 24.0f + (calls % 7) * 0.3f; }
  float readHumidity() { return 55.0f + (calls % 5); }
};
