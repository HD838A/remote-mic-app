#pragma once

#include <filesystem>
#include <fstream>
#include <mutex>
#include <string_view>

namespace remotemic {

class FileLogger {
public:
    explicit FileLogger(std::filesystem::path log_file);

    [[nodiscard]] bool ready() const noexcept;
    void info(std::string_view message);

private:
    std::filesystem::path log_file_;
    std::ofstream stream_;
    mutable std::mutex mutex_;
};

} // namespace remotemic
