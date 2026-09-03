#pragma once

#include <cstdint>
#include <span>

namespace remotemic {

struct PcmFormat {
    std::uint32_t sample_rate{16'000};
    std::uint16_t channels{1};
    std::uint16_t bits_per_sample{16};
};

class IAudioRoute {
public:
    virtual ~IAudioRoute() = default;
    virtual bool start(PcmFormat format) = 0;
    virtual bool write(std::span<const std::int16_t> samples) = 0;
    virtual void stop() noexcept = 0;
};

} // namespace remotemic
