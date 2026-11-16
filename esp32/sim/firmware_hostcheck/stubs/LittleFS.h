#pragma once
// In-memory LittleFS for the host build. g_fs survives "reboots" inside one
// host run (call setup()/fb::begin() again to model a power cycle), like the
// NVS stub in Preferences.h. g_fs_mount_fails models a corrupt partition.
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <string>

inline std::map<std::string, std::shared_ptr<std::string>>& g_fs() {
  static std::map<std::string, std::shared_ptr<std::string>> fs;
  return fs;
}
inline bool& g_fs_mount_fails() { static bool f = false; return f; }

class File {
 public:
  File() {}
  File(std::shared_ptr<std::string> b) : buf(std::move(b)) {}
  explicit operator bool() const { return (bool)buf; }
  bool seek(uint32_t p) { if (!buf) return false; pos = p; return true; }
  size_t read(uint8_t* out, size_t n) {
    if (!buf || pos >= buf->size()) return 0;
    size_t k = buf->size() - pos < n ? buf->size() - pos : n;
    memcpy(out, buf->data() + pos, k);
    pos += k;
    return k;
  }
  size_t write(const uint8_t* in, size_t n) {
    if (!buf) return 0;
    if (pos + n > buf->size()) buf->resize(pos + n);
    memcpy(&(*buf)[pos], in, n);
    pos += n;
    return n;
  }
  size_t size() const { return buf ? buf->size() : 0; }
  void flush() {}
  void close() { buf.reset(); }

 private:
  std::shared_ptr<std::string> buf;
  size_t pos = 0;
};

struct LittleFSClass {
  bool begin(bool /*formatOnFail*/) { return !g_fs_mount_fails(); }
  bool exists(const char* p) { return g_fs().count(p) > 0; }
  bool remove(const char* p) { return g_fs().erase(p) > 0; }
  File open(const char* p, const char* mode) {
    auto& fs = g_fs();
    if (mode[0] == 'w') { fs[p] = std::make_shared<std::string>(); return File(fs[p]); }
    auto it = fs.find(p);
    if (it == fs.end()) return File();
    return File(it->second);
  }
};
inline LittleFSClass LittleFS;
