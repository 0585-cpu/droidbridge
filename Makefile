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
	cmake -S core -B build/core-fuzz -DCMAKE_BUILD_TYPE=Debug -DDROIDBRIDGE_BUILD_FUZZERS=ON -DBUILD_TESTING=OFF -DCMAKE_C_COMPILER=$(FUZZ_CC)
	cmake --build build/core-fuzz --parallel
	mkdir -p build/core-fuzz/corpus-header build/core-fuzz/corpus-open
	build/core-fuzz/fuzz_dbp_header build/core-fuzz/corpus-header -max_total_time=$(FUZZ_SECONDS) -max_len=4096 -timeout=2 >/dev/null 2>&1 && echo "fuzz_dbp_header: no crash"
	build/core-fuzz/fuzz_open_tcp build/core-fuzz/corpus-open -max_total_time=$(FUZZ_SECONDS) -max_len=4096 -timeout=2 >/dev/null 2>&1 && echo "fuzz_open_tcp: no crash"

# Android relay (needs JDK 17; JAVA_HOME auto-detected from the Gradle-managed JDK if present).
ANDROID_JDK ?= $(firstword $(wildcard $(HOME)/.gradle/jdks/eclipse_adoptium-17-*/*/Contents/Home))
.PHONY: test-android smoke-android
test-android:
	cd android && JAVA_HOME=$(ANDROID_JDK) ./gradlew testDebugUnitTest lintDebug assembleDebug

smoke-android:
	./scripts/smoke-android-relay.sh
