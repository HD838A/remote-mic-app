#pragma once

#include <filesystem>

namespace remotemic {

struct RuntimePaths {
    std::filesystem::path data_directory;
    std::filesystem::path logs_directory;
    std::filesystem::path runtime_log;
    std::filesystem::path settings_file;
};

[[nodiscard]] RuntimePaths resolve_runtime_paths();
[[nodiscard]] bool ensure_runtime_directories(const RuntimePaths& paths);

} // namespace remotemic
