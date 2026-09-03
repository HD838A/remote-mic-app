#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <span>

namespace remotemic {

class IBleTransport {
public:
    using BytesReceived = std::function<void(std::span<const std::uint8_t>)>;

    virtual ~IBleTransport() = default;
    virtual void set_bytes_received(BytesReceived callback) = 0;
    virtual bool connect() = 0;
    virtual void disconnect() noexcept = 0;
    virtual bool write(std::span<const std::uint8_t> bytes) = 0;
};

} // namespace remotemic
