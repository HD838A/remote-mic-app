#include "remotemic/app/application.hpp"
#include "remotemic/interfaces/audio_route.hpp"
#include "remotemic/platform/runtime_paths.hpp"

#include <iostream>
#include <string>

namespace {

int failures = 0;

void expect(bool condition, const std::string& message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}
} // namespace

int main() {
    expect(!remotemic::Application::version().empty(), "version must not be empty");

    const auto paths = remotemic::resolve_runtime_paths();
    expect(!paths.data_directory.empty(), "data directory must be resolved");
    expect(paths.runtime_log.filename() == "runtime.log", "runtime log name must be stable");

    const remotemic::PcmFormat format;
    expect(format.sample_rate == 16'000, "RC003 baseline sample rate must be 16 kHz");
    expect(format.channels == 1, "RC003 baseline must be mono");
    expect(format.bits_per_sample == 16, "PCM baseline must use 16-bit samples");

    if (failures == 0) {
        std::cout << "All core tests passed\n";
    }
    return failures == 0 ? 0 : 1;
}
