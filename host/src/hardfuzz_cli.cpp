// hardfuzz_cli.cpp — the `hardfuzz` command-line campaign runner.
//
//   hardfuzz run <campaign.json>                       dry run: schedule + arm bytes
//   hardfuzz run <campaign.json> --arm-port <cmod> --dut-port <stm32>   LIVE
//
// Dry run shows the coverage-guided plan and exact register writes. Live mode arms the
// FPGA over the Cmod's UART and drives the STM32 (which must run the run-command
// firmware: send 'R' -> it runs one transaction and prints a RESULT line), collecting
// real pass/fail verdicts. --json / --csv write the report either way.
#include "hardfuzz/json.hpp"
#include "hardfuzz/reg_client.hpp"
#include "hardfuzz/dut_serial.hpp"
#include "hardfuzz/report.hpp"
#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using namespace hardfuzz;

struct CaptureTransport : Transport {          // logs arm bytes as hex, sends nowhere
    std::string log;
    void send(const uint8_t* p, std::size_t n) override {
        for (std::size_t k = 0; k < n; ++k) { char b[4]; std::snprintf(b, sizeof b, "%02X ", p[k]); log += b; }
    }
    std::size_t recv(uint8_t*, std::size_t) override { return 0; }
};

static std::string read_file(const std::string& path) {
    std::ifstream f(path); std::ostringstream ss; ss << f.rdbuf(); return ss.str();
}

static bool load(const std::string& file, FaultCampaign& c) {
    std::string txt = read_file(file);
    if (txt.empty()) { std::fprintf(stderr, "error: cannot read %s\n", file.c_str()); return false; }
    try { c = campaign_from_json(json_parse(txt)); }
    catch (const std::exception& e) { std::fprintf(stderr, "error: %s\n", e.what()); return false; }
    return true;
}

static void banner(const FaultCampaign& c, const char* mode) {
    std::printf("campaign : %s\ntarget   : %s\nstandard : %s\n%zu scenarios — %s\n\n",
                c.name.c_str(), c.target.c_str(), c.standard.c_str(), c.faults.size(), mode);
}

struct OutPaths { std::string json, csv, html; };

static void write_reports(const FaultCampaign& c, const std::vector<ScenarioResult>& rs,
                          const CoverageTracker& cov, const OutPaths& out) {
    if (!out.json.empty() && write_file(out.json, report_json(c, rs, cov))) std::printf("wrote %s\n", out.json.c_str());
    if (!out.csv.empty()  && write_file(out.csv,  report_csv(rs)))          std::printf("wrote %s\n", out.csv.c_str());
    if (!out.html.empty() && write_file(out.html, report_html(c, rs, cov))) std::printf("wrote %s\n", out.html.c_str());
}

// ---- dry run ------------------------------------------------------------
static int cmd_dry(const FaultCampaign& c, const OutPaths& out) {
    banner(c, "DRY RUN (no DUT); coverage-guided order + arming:");
    std::printf("ord  id            proto  a      b        req     cov  arm bytes\n");
    CoverageTracker cov; Scheduler sched;
    std::vector<std::size_t> pending; for (std::size_t i = 0; i < c.faults.size(); ++i) pending.push_back(i);
    std::vector<ScenarioResult> planned; int ord = 0;
    while (!pending.empty()) {
        std::size_t bi = sched.next(c.faults, pending, cov);
        const Fault& f = c.faults[bi]; int covnow = cov.count(f);
        CaptureTransport cap; RegClient rc(cap); rc.arm(f);
        std::printf("%3d  %-12s  %-4s  %-5d  %-7d  %-6s  %-3s  %s\n", ord++, f.id.c_str(),
                    to_string(f.proto), f.a, f.b, f.requirement.c_str(), covnow == 0 ? "new" : "rep", cap.log.c_str());
        ScenarioResult sr; sr.fault = f; sr.coverage_at_run = covnow; sr.ran = false; sr.dut = {false, "(dry run)"};
        planned.push_back(sr);
        cov.mark(f); pending.erase(std::remove(pending.begin(), pending.end(), bi), pending.end());
    }
    std::printf("\ncoverage: %zu unique tuples across %zu injections\n", cov.unique(), cov.total());
    write_reports(c, planned, cov, out);
    return 0;
}

// ---- live run -----------------------------------------------------------
#if defined(HARDFUZZ_ENABLE_SERIAL)
static int cmd_live(const FaultCampaign& c, const std::string& armPort, const std::string& dutPort,
                    const OutPaths& out) {
    SerialTransport armT(armPort), dutT(dutPort);
    RegClient reg(armT);
    SerialDutRunner dut(dutT);
    CoverageTracker cov;
    CampaignRunner runner(reg, dut, cov);
    // give each arm time to reach + apply on the FPGA before the STM32 runs
    runner.set_after_arm([] { std::this_thread::sleep_for(std::chrono::milliseconds(40)); });

    banner(c, "LIVE (arming FPGA + driving STM32):");
    auto rs = runner.run(c);

    std::printf("id            proto  a      b        expected    verdict  detail\n");
    for (auto& r : rs)
        std::printf("%-12s  %-4s  %-5d  %-7d  %-10s  %-7s  %s\n", r.fault.id.c_str(),
                    to_string(r.fault.proto), r.fault.a, r.fault.b, r.fault.expect.c_str(),
                    r.pass ? "PASS" : "FAIL", r.dut.detail.c_str());
    Summary sm = summarize(rs, cov);
    std::printf("\n%d/%d passed, %d failed; coverage %zu unique tuples\n",
                sm.passed, sm.total, sm.failed, sm.unique);
    write_reports(c, rs, cov, out);
    return sm.failed ? 1 : 0;    // nonzero exit if any scenario failed (CI-friendly)
}
#endif

int main(int argc, char** argv) {
    if (argc >= 3 && std::string(argv[1]) == "run") {
        std::string file = argv[2], armPort, dutPort;
        OutPaths out;
        for (int i = 3; i + 1 < argc; ++i) {
            std::string a = argv[i];
            if      (a == "--json")     out.json = argv[++i];
            else if (a == "--csv")      out.csv  = argv[++i];
            else if (a == "--html")     out.html = argv[++i];
            else if (a == "--arm-port") armPort  = argv[++i];
            else if (a == "--dut-port") dutPort  = argv[++i];
        }
        FaultCampaign c;
        if (!load(file, c)) return 1;
        if (!armPort.empty() && !dutPort.empty()) {
#if defined(HARDFUZZ_ENABLE_SERIAL)
            try { return cmd_live(c, armPort, dutPort, out); }
            catch (const std::exception& e) { std::fprintf(stderr, "serial error: %s\n", e.what()); return 1; }
#else
            std::fprintf(stderr, "live mode needs serial support (build with -DHARDFUZZ_ENABLE_SERIAL)\n");
            return 2;
#endif
        }
        return cmd_dry(c, out);
    }
    std::fprintf(stderr,
        "hardfuzz — HardFuzz campaign runner\n"
        "  hardfuzz run <campaign.json> [--json out] [--csv out] [--html out]   (dry run)\n"
        "  hardfuzz run <campaign.json> --arm-port <cmod> --dut-port <stm32> [--html out]  (live)\n\n"
        "Dry run shows the coverage-guided schedule + exact arm bytes. Live mode arms the\n"
        "FPGA (Cmod UART) and drives the STM32 run-command firmware for real verdicts.\n");
    return 2;
}
