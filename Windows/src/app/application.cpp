#include "remotemic/app/application.hpp"

#include "remotemic/logging/file_logger.hpp"
#include "remotemic/platform/runtime_paths.hpp"

namespace remotemic {

std::string Application::version() {
    return REMOTEMIC_VERSION;
}

DiagnosticReport Application::diagnose() const {
    const auto paths = resolve_runtime_paths();
    const bool ready = ensure_runtime_directories(paths);

    if (ready) {
        FileLogger logger{paths.runtime_log};
        logger.info("Diagnostic check completed");
    }

    return DiagnosticReport{
        .version = version(),
        .data_directory = paths.data_directory,
        .log_file = paths.runtime_log,
        .data_directory_ready = ready,
    };
}

} // namespace remotemic
