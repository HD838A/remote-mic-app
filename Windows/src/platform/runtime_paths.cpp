#include "remotemic/platform/runtime_paths.hpp"

#include <cstdlib>
#include <system_error>

namespace remotemic {
namespace {

std::filesystem::path local_app_data() {
#ifdef _WIN32
    char* value = nullptr;
    std::size_t length = 0;
    if (_dupenv_s(&value, &length, "LOCALAPPDATA") == 0 && value != nullptr) {
        const std::filesystem::path path{value};
        std::free(value);
        return path;
    }
    std::free(value);
#else
    if (const char* value = std::getenv("XDG_STATE_HOME")) {
        return value;
    }
    if (const char* home = std::getenv("HOME")) {
        return std::filesystem::path{home} / ".local" / "state";
    }
#endif
    return std::filesystem::temp_directory_path();
}

} // namespace

RuntimePaths resolve_runtime_paths() {
    const auto data = local_app_data() / "RemoteMic";
    const auto logs = data / "logs";
    return RuntimePaths{
        .data_directory = data,
        .logs_directory = logs,
        .runtime_log = logs / "runtime.log",
        .settings_file = data / "settings.json",
    };
}

bool ensure_runtime_directories(const RuntimePaths& paths) {
    std::error_code error;
    std::filesystem::create_directories(paths.logs_directory, error);
    return !error && std::filesystem::is_directory(paths.logs_directory, error) && !error;
}

} // namespace remotemic
