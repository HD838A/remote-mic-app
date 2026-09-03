#include "remotemic/app/application.hpp"

#include <iostream>
#include <string_view>

namespace {

void print_usage() {
    std::cout << "RemoteMic Windows\n"
                 "Usage:\n"
                 "  remotemic --version\n"
                 "  remotemic --diagnose\n";
}
} // namespace

int main(int argc, char* argv[]) {
    if (argc != 2) {
        print_usage();
        return 2;
    }

    const std::string_view option{argv[1]};
    if (option == "--version") {
        std::cout << remotemic::Application::version() << '\n';
        return 0;
    }

    if (option == "--diagnose") {
        const remotemic::Application app;
        const auto report = app.diagnose();
        std::cout << "version=" << report.version << '\n'
                  << "data_directory=" << report.data_directory.string() << '\n'
                  << "log_file=" << report.log_file.string() << '\n'
                  << "data_directory_ready=" << (report.data_directory_ready ? "true" : "false")
                  << '\n';
        return report.data_directory_ready ? 0 : 1;
    }

    print_usage();
    return 2;
}
