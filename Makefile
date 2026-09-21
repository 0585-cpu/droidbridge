.PHONY: configure-core test-core verify-foundation
configure-core:
	cmake -S core -B build/core -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

test-core: configure-core
	cmake --build build/core --parallel
	ctest --test-dir build/core --output-on-failure

verify-foundation: test-core
	python3 tools/check_environment.py
	python3 tools/generate_protocol_vectors.py --check
