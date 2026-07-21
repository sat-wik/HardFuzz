// hardfuzz/campaign.hpp — campaign model, DUT runner, and the campaign runner.
#pragma once
#include "fault.hpp"
#include "coverage.hpp"
#include "reg_client.hpp"
#include <algorithm>
#include <functional>
#include <string>
#include <vector>

namespace hardfuzz {

// What the DUT reported after a transaction under fault.
struct DutResult {
    bool        fault_observed = false;   // did the DUT catch/handle the injected fault?
    std::string detail;                   // free-text, e.g. "FLIP bit 3" / "I2C timeout"
};

// Executes one transaction on the DUT and returns what it observed. Real impl drives
// the STM32 and parses its report; MockDut lets the whole layer run offline.
struct DutRunner {
    virtual DutResult run(const Fault& armed) = 0;
    virtual ~DutRunner() = default;
};
struct MockDut : DutRunner {
    std::function<DutResult(const Fault&)> policy;
    explicit MockDut(std::function<DutResult(const Fault&)> p) : policy(std::move(p)) {}
    DutResult run(const Fault& f) override { return policy(f); }
};

struct FaultCampaign {
    std::string        name;
    std::string        target;     // DUT under test, e.g. "STM32F446 SPI flash"
    std::string        standard;   // evidence standard, e.g. "IEC 61508"
    std::vector<Fault> faults;
};

struct ScenarioResult {
    Fault     fault;
    DutResult dut;
    bool      pass = false;
    bool      ran = true;            // false => planned only (dry run), verdict "PLANNED"
    int       coverage_at_run = 0;   // how many times this tuple had run before (0 = novel)
};

// Verdict: did the DUT behave as the scenario required?
inline bool evaluate(const Fault& f, const DutResult& r) {
    if (f.expect == "tolerated") return !r.fault_observed;  // must ride through
    return r.fault_observed;                                // "detected" (default)
}

// Runs a campaign under coverage-guided scheduling: at each step it arms the
// least-covered pending fault, runs the DUT, disarms, and records the verdict.
class CampaignRunner {
    RegClient&            reg_;
    DutRunner&            dut_;
    CoverageTracker&      cov_;
    Scheduler             sched_;
    std::function<void()> after_arm_;   // live: settle time so the FPGA is armed before run
public:
    CampaignRunner(RegClient& r, DutRunner& d, CoverageTracker& c)
        : reg_(r), dut_(d), cov_(c) {}

    // Hook run after arm(), before the DUT runs — used in live mode to let the arm
    // fully reach/apply on the FPGA before triggering the STM32 (they're on separate
    // serial links, so without this the run can race ahead of the arm).
    void set_after_arm(std::function<void()> f) { after_arm_ = std::move(f); }

    std::vector<ScenarioResult> run(const FaultCampaign& c) {
        std::vector<ScenarioResult> results;
        std::vector<std::size_t> pending;
        for (std::size_t i = 0; i < c.faults.size(); ++i) pending.push_back(i);

        while (!pending.empty()) {
            std::size_t bi = sched_.next(c.faults, pending, cov_);
            const Fault& f = c.faults[bi];

            ScenarioResult sr;
            sr.fault           = f;
            sr.coverage_at_run = cov_.count(f);

            reg_.arm(f);
            if (after_arm_) after_arm_();     // let the arm settle on the FPGA (live mode)
            sr.dut = dut_.run(f);
            reg_.disarm();
            cov_.mark(f);

            sr.pass = evaluate(f, sr.dut);
            results.push_back(sr);
            pending.erase(std::remove(pending.begin(), pending.end(), bi), pending.end());
        }
        return results;
    }
};

// Small summary helper.
struct Summary { int total = 0, passed = 0, failed = 0; std::size_t unique = 0; };
inline Summary summarize(const std::vector<ScenarioResult>& rs, const CoverageTracker& cov) {
    Summary s; s.total = (int)rs.size(); s.unique = cov.unique();
    for (auto& r : rs) (r.pass ? s.passed : s.failed)++;
    return s;
}

}  // namespace hardfuzz
