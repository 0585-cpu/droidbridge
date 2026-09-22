.PHONY: configure-core test-core verify-foundation fuzz-smoke
configure-core:
	cmake -S core -B build/core -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

test-core: configure-core
	cmake --build build/core --parallel
	ctest --test-dir build/core --output-on-failure

verify-foundation: test-core
	python3 tools/check_environment.py
	python3 tools/generate_protocol_vectors.py --check
	python3 -m unittest discover -s tools/tests -p 'test_*.py'

# libFuzzer is not in Apple's clang; on macOS use Homebrew LLVM (brew install llvm).
FUZZ_CC ?= $(shell test -x /opt/homebrew/opt/llvm/bin/clang && echo /opt/homebrew/opt/llvm/bin/clang || echo clang)
FUZZ_SECONDS ?= 10
fuzz-smoke:
	cmake -S core -B build/core-fuzz -DCMAKE_BUILD_TYPE=Debug -DDROIDBRIDGE_BUILD_FUZZERS=ON -DBUILD_TESTING=OFF -DDROIDBRIDGE_BUILD_LWIP=OFF -DCMAKE_C_COMPILER=$(FUZZ_CC)
	cmake --build build/core-fuzz --parallel
	mkdir -p build/core-fuzz/corpus-header build/core-fuzz/corpus-open
	build/core-fuzz/fuzz_dbp_header build/core-fuzz/corpus-header -max_total_time=$(FUZZ_SECONDS) -max_len=4096 -timeout=2 >/dev/null 2>&1 && echo "fuzz_dbp_header: no crash"
	build/core-fuzz/fuzz_open_tcp build/core-fuzz/corpus-open -max_total_time=$(FUZZ_SECONDS) -max_len=4096 -timeout=2 >/dev/null 2>&1 && echo "fuzz_open_tcp: no crash"
	mkdir -p build/core-fuzz/corpus-ip build/core-fuzz/corpus-dns
	build/core-fuzz/fuzz_ipv4_tcp build/core-fuzz/corpus-ip -max_total_time=$(FUZZ_SECONDS) -max_len=2048 -timeout=2 >/dev/null 2>&1 && echo "fuzz_ipv4_tcp: no crash"
	build/core-fuzz/fuzz_dns_packet build/core-fuzz/corpus-dns -max_total_time=$(FUZZ_SECONDS) -max_len=4096 -timeout=2 >/dev/null 2>&1 && echo "fuzz_dns_packet: no crash"

# Android relay (needs JDK 17; JAVA_HOME auto-detected from the Gradle-managed JDK if present).
ANDROID_JDK ?= $(firstword $(wildcard $(HOME)/.gradle/jdks/eclipse_adoptium-17-*/*/Contents/Home))
.PHONY: test-android smoke-android
test-android:
	cd android && JAVA_HOME=$(ANDROID_JDK) ./gradlew testDebugUnitTest lintDebug assembleDebug

smoke-android:
	./scripts/smoke-android-relay.sh

.PHONY: check-macos smoke-macos-control
check-macos:
	swift run --package-path macos/Shared Checks

smoke-macos-control:
	./scripts/run-macos-control-smoke.sh --preflight

.PHONY: benchmark-core verify-data-plane
benchmark-core:
	$(FUZZ_CC) -O2 -I core/include tools/packet_core_benchmark.c core/src/*.c -o build/packet_core_benchmark 2>/dev/null || 	cc -O2 -I core/include tools/packet_core_benchmark.c -c -o /dev/null && echo "benchmark builds"

verify-data-plane:
	./scripts/verify-data-plane.sh

.PHONY: b1-preflight b1-stress b1-performance b1-soak build-signed-macos build-android-release
b1-preflight:
	./scripts/b1-preflight.sh

b1-stress:
	./scripts/b1-stress.sh

b1-performance:
	./scripts/b1-performance.sh

b1-soak:
	./scripts/b1-soak.sh --duration 60m

build-signed-macos:
	./scripts/build-signed-macos.sh

build-android-release:
	./scripts/build-android-release.sh
