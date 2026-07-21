// test_campaign.cpp — self-check for the campaign layer, entirely against mocks.
// Verifies: register arming, coverage-guided scheduling, pass/fail verdicts, and report
// generation — no board required. Build: c++ -std=c++17 -Iinclude test/test_campaign.cpp
#include "hardfuzz/campaign.hpp"
#include "hardfuzz/report.hpp"
#include "hardfuzz/dut_serial.hpp"
#include <cstdio>
#include <deque>
#include <string>

using namespace hardfuzz;

// Fake STM32 DUT: on receiving 'R', queues a canned firmware transcript (incl. RESULT).
struct FakeDut : Transport {
    std::string canned; std::deque<char> out;
    explicit FakeDut(std::string c) : canned(std::move(c)) {}
    void send(const uint8_t* p, std::size_t n) override {
        for (std::size_t i = 0; i < n; ++i) if (p[i] == 'R') for (char ch : canned) out.push_back(ch);
    }
    std::size_t recv(uint8_t* p, std::size_t n) override {
        std::size_t k = 0; while (k < n && !out.empty()) { p[k++] = out.front(); out.pop_front(); } return k;
    }
};

static int errors = 0;
static void check(bool cond, const char* what) {
    std::printf("%s: %s\n", cond ? "PASS" : "FAIL", what);
    if (!cond) errors++;
}

int main() {
    // ---- 1. RegClient arms the right registers (SPI) ----
    {
        MockTransport mt;
        RegClient rc(mt);
        rc.arm(Fault{"x", Protocol::Spi, /*frame*/5, /*bit*/3, "detected", ""});
        const uint8_t* r = mt.regs();
        check(r[3] == 3 && r[1] == 5 && r[2] == 0 && r[0] == 0x01, "SPI arm writes reg3=bit,reg1/2=frame,reg0=enable");
    }
    // ---- I2C arm ----
    {
        MockTransport mt; RegClient rc(mt);
        rc.arm(Fault{"y", Protocol::I2c, /*byte*/2, /*stretch*/60000, "detected", ""});
        const uint8_t* r = mt.regs();
        check(r[1] == 2 && r[2] == (60000 & 0xFF) && r[3] == ((60000 >> 8) & 0xFF) && r[0] == 1,
              "I2C arm writes reg1=byte,reg2/3=stretch,reg0=enable");
    }

    // ---- 2. Full campaign with a duplicate tuple + a failing scenario ----
    FaultCampaign c;
    c.name = "smoke"; c.target = "STM32F446"; c.standard = "IEC 61508";
    c.faults = {
        {"SPI-1",        Protocol::Spi, 5, 3,     "detected",  "SR-1"},
        {"SPI-dup",      Protocol::Spi, 5, 3,     "detected",  "SR-1b"},  // duplicate tuple
        {"I2C-1",        Protocol::I2c, 2, 60000, "detected",  "SR-2"},
        {"CAN-1",        Protocol::Can, 20, 1,    "detected",  "SR-3"},
        {"SPI-nodetect", Protocol::Spi, 7, 0,     "detected",  "SR-4"},   // DUT misses -> FAIL
        {"I2C-tol",      Protocol::I2c, 3, 100,   "tolerated", "SR-5"},   // rides through -> PASS
    };

    MockTransport mt; RegClient rc(mt); CoverageTracker cov;
    MockDut dut([](const Fault& f) -> DutResult {
        if (f.id == "SPI-nodetect")   return {false, "no flip seen"};
        if (f.expect == "tolerated")  return {false, "rode through"};
        return {true, std::string("fault seen on ") + to_string(f.proto)};
    });
    CampaignRunner runner(rc, dut, cov);
    auto rs = runner.run(c);

    check(rs.size() == 6, "all 6 scenarios ran");

    // scheduler: the duplicate tuple must run LAST (deprioritized once its tuple is hit)
    check(rs.back().fault.id == "SPI-dup" && rs.back().coverage_at_run == 1,
          "duplicate tuple was scheduled last (coverage-guided)");
    bool novel_first = true;
    for (std::size_t i = 0; i + 1 < rs.size(); ++i)
        if (rs[i].coverage_at_run != 0) novel_first = false;
    check(novel_first, "every non-final scenario ran a novel tuple first");

    // coverage: 5 distinct tuples (SPI-1 and SPI-dup share one)
    check(cov.unique() == 5 && cov.total() == 6, "coverage tracked 5 unique tuples / 6 injections");

    // verdicts
    Summary sm = summarize(rs, cov);
    check(sm.passed == 5 && sm.failed == 1, "5 pass, 1 fail (the missed SPI fault)");
    for (auto& r : rs)
        if (r.fault.id == "SPI-nodetect") check(!r.pass, "SPI-nodetect correctly FAILs");
        else if (r.fault.id == "I2C-tol") check(r.pass, "I2C-tol (tolerated + not observed) PASSes");

    // ---- 3. reports generate and contain the expected evidence ----
    std::string j = report_json(c, rs, cov);
    std::string csv = report_csv(rs);
    check(j.find("\"standard\": \"IEC 61508\"") != std::string::npos, "JSON carries the standard");
    check(j.find("\"verdict\": \"FAIL\"") != std::string::npos, "JSON records the FAIL verdict");
    check(j.find("\"requirement\": \"SR-2\"") != std::string::npos, "JSON carries requirement traceability");
    check(csv.find("SPI-nodetect,SR-4,spi,7,0,detected,0,FAIL") != std::string::npos, "CSV row is correct");

    // ---- 4. DUT-over-serial: RESULT parsing + SerialDutRunner ----
    check(parse_result("...table...\r\nRESULT 1 SPI flip on 1 frame(s)\r\n").fault_observed,
          "parse_result reads observed=1");
    check(!parse_result("RESULT 0 SPI clean\r\n").fault_observed, "parse_result reads observed=0");
    check(parse_result("RESULT 1 I2C stretch fault\r\n").detail == "I2C stretch fault",
          "parse_result extracts detail");
    check(!parse_result("no marker here").fault_observed, "parse_result handles missing marker");
    {
        FakeDut fake("dbyte...\r\nRESULT 1 I2C stretch fault\r\n");
        SerialDutRunner sdr(fake);
        DutResult dr = sdr.run(Fault{});
        check(dr.fault_observed && dr.detail == "I2C stretch fault",
              "SerialDutRunner sends 'R' and parses the RESULT line");
    }

    std::printf(errors ? "\n%d TEST(S) FAILED\n" : "\nALL TESTS PASSED\n", errors);
    return errors ? 1 : 0;
}
