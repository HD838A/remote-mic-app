#pragma once

#include <filesystem>
#include <string>

namespace remotemic {

struct DiagnosticReport {
    std::string version;
    std::filesystem::path data_directory;
    std::filesystem::path log_file;
    bool data_directory_ready{false};
};

class Application {
public:
    [[nodiscard]] static std::string version();
    [[nodiscard]] DiagnosticReport diagnose() const;
};

} // namespace remotemic
