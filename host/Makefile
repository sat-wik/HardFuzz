# HardFuzz host — header-only C++17 library + `hardfuzz` CLI + self-test.
# Only the CLI and test are compiled; everything in include/ is header-only.
CXX      ?= c++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Iinclude
BUILD     = build

.PHONY: all cli test run clean

all: cli test

cli: $(BUILD)/hardfuzz
$(BUILD)/hardfuzz: src/hardfuzz_cli.cpp $(wildcard include/hardfuzz/*.hpp)
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -DHARDFUZZ_ENABLE_SERIAL $< -o $@   # POSIX serial for live mode

test: $(BUILD)/test_campaign
	./$(BUILD)/test_campaign
$(BUILD)/test_campaign: test/test_campaign.cpp $(wildcard include/hardfuzz/*.hpp)
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) $< -o $@

# Dry-run the example campaign through the CLI.
run: cli
	./$(BUILD)/hardfuzz run campaigns/example.json

clean:
	rm -rf $(BUILD)
