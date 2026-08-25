#include "remotemic/logging/file_logger.hpp"

#include <chrono>
#include <iomanip>

namespace remotemic {

FileLogger::FileLogger(std::filesystem::path log_file)
    : log_file_(std::move(log_file)), stream_(log_file_, std::ios::app) {}

bool FileLogger::ready() const noexcept {
    return stream_.is_open();
}

void FileLogger::info(std::string_view message) {
    std::scoped_lock lock{mutex_};
    if (!stream_) {
        return;
    }

    const auto now = std::chrono::system_clock::now();
    const auto timestamp = std::chrono::system_clock::to_time_t(now);
    std::tm local_time{};
#ifdef _WIN32
    localtime_s(&local_time, &timestamp);
#else
    localtime_r(&timestamp, &local_time);
#endif
    stream_ << std::put_time(&local_time, "%Y-%m-%dT%H:%M:%S") << " [info] " << message
            << '\n';
    stream_.flush();
}

} // namespace remotemic
