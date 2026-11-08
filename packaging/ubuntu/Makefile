# Run from the repository root with make -f packaging/ubuntu/Makefile.
SHELL := /bin/sh
BUILD ?= .build/ubuntu
SWIFTC ?= swiftc
SWIFT_LICENSE ?= $(dir $(realpath $(shell command -v $(SWIFTC))))../share/swift/LICENSE.txt
ARCH := $(shell dpkg --print-architecture)
VERSION ?= 0~local+$(shell git rev-parse --short=12 HEAD)
LIB := $(BUILD)/libatvv.so

.PHONY: all test package
all: $(LIB)

$(LIB): Sources/RemoteMic/ATVVProtocol.swift Apps/Ubuntu/Audio.swift
	mkdir -p $(BUILD)
	$(SWIFTC) -module-cache-path $(BUILD)/modules -O -emit-library -static-stdlib -o $@ $^
	strip --strip-unneeded $@

test: $(LIB)
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=Apps/Ubuntu SAYALL_TEST_LIBRARY=$(abspath $(LIB)) /usr/bin/python3 -m unittest discover -s Tests/Ubuntu -v

# Stage each package in a fresh directory so deleted files and Python caches cannot leak in.
$(BUILD)/Swift-LICENSE.txt:
	install -Dm 644 $(SWIFT_LICENSE) $@

package: $(LIB) $(BUILD)/Swift-LICENSE.txt
	set -eu; stage=$$(mktemp -d); trap 'rm -rf "$$stage"' EXIT; \
	app="$$stage/usr/lib/sayall-ubuntu"; mkdir -p "$$app" "$$stage/usr/bin" "$$stage/DEBIAN"; \
	install -m 755 Apps/Ubuntu/bridge.py "$$app/bridge.py"; \
	install -m 644 Apps/Ubuntu/audio.py $(LIB) "$$app/"; \
	ln -s ../lib/sayall-ubuntu/bridge.py "$$stage/usr/bin/sayall-ubuntu"; \
	install -Dm 644 packaging/ubuntu/65-sayall-rc003.hwdb "$$stage/usr/lib/udev/hwdb.d/65-sayall-rc003.hwdb"; \
	install -Dm 644 packaging/ubuntu/sayall-ubuntu.service "$$stage/usr/lib/systemd/user/sayall-ubuntu.service"; \
	install -Dm 644 LICENSE.md "$$stage/usr/share/doc/sayall-ubuntu/copyright"; \
	install -m 644 $(BUILD)/Swift-LICENSE.txt COPYRIGHT.md THIRD_PARTY_NOTICES.md "$$stage/usr/share/doc/sayall-ubuntu/"; \
	install -Dm 644 Testing/HardwareVoiceAudioContract.md "$$stage/usr/share/doc/sayall-ubuntu/HardwareVoiceAudioContract.md"; \
	install -Dm 644 Testing/Ubuntu.md "$$stage/usr/share/doc/sayall-ubuntu/Ubuntu.md"; \
	sed -e 's/@ARCH@/$(ARCH)/g' -e 's/@VERSION@/$(VERSION)/g' packaging/ubuntu/control >"$$stage/DEBIAN/control"; \
	chmod 755 "$$stage"; \
	dpkg-deb --root-owner-group --build "$$stage" $(BUILD)/sayall-ubuntu_$(VERSION)_$(ARCH).deb
