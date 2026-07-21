// hardfuzz/report.hpp — JSON / CSV report export with safety-standard traceability.
#pragma once
#include "campaign.hpp"
#include <ctime>
#include <fstream>
#include <sstream>
#include <string>

namespace hardfuzz {

inline std::string json_escape(const std::string& s) {
    std::string o;
    for (char c : s) {
        switch (c) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n";  break;
            case '\t': o += "\\t";  break;
            default:   o += c;      break;
        }
    }
    return o;
}

// JSON report: campaign metadata, per-scenario traceability records (id / requirement /
// protocol / target tuple / expected / observed / verdict), and a coverage summary.
// Field names align with IEC 61508 / ISO 26262 evidence expectations.
inline std::string report_json(const FaultCampaign& c,
                               const std::vector<ScenarioResult>& rs,
                               const CoverageTracker& cov) {
    Summary sm = summarize(rs, cov);
    std::ostringstream o;
    o << "{\n";
    o << "  \"campaign\": \"" << json_escape(c.name) << "\",\n";
    o << "  \"target\": \"" << json_escape(c.target) << "\",\n";
    o << "  \"standard\": \"" << json_escape(c.standard) << "\",\n";
    o << "  \"summary\": { \"total\": " << sm.total
      << ", \"passed\": " << sm.passed
      << ", \"failed\": " << sm.failed
      << ", \"unique_tuples\": " << sm.unique << " },\n";
    o << "  \"results\": [\n";
    for (std::size_t i = 0; i < rs.size(); ++i) {
        const auto& r = rs[i];
        auto pn = r.fault.param_names();
        o << "    {"
          << " \"id\": \"" << json_escape(r.fault.id) << "\","
          << " \"requirement\": \"" << json_escape(r.fault.requirement) << "\","
          << " \"protocol\": \"" << to_string(r.fault.proto) << "\","
          << " \"" << pn.first << "\": " << r.fault.a << ","
          << " \"" << pn.second << "\": " << r.fault.b << ","
          << " \"expected\": \"" << json_escape(r.fault.expect) << "\","
          << " \"observed\": \"" << json_escape(r.dut.detail) << "\","
          << " \"fault_observed\": " << (r.dut.fault_observed ? "true" : "false") << ","
          << " \"verdict\": \"" << (r.ran ? (r.pass ? "PASS" : "FAIL") : "PLANNED") << "\""
          << " }" << (i + 1 < rs.size() ? "," : "") << "\n";
    }
    o << "  ],\n";
    o << "  \"coverage\": [\n";
    std::size_t k = 0;
    for (auto& kv : cov.map()) {
        o << "    { \"protocol\": \"" << to_string(kv.first.proto) << "\", \"a\": "
          << kv.first.a << ", \"b\": " << kv.first.b << ", \"hits\": " << kv.second << " }"
          << (++k < cov.map().size() ? "," : "") << "\n";
    }
    o << "  ]\n}\n";
    return o.str();
}

// CSV report — one row per scenario, spreadsheet/traceability-matrix friendly.
inline std::string report_csv(const std::vector<ScenarioResult>& rs) {
    std::ostringstream o;
    o << "id,requirement,protocol,a,b,expected,fault_observed,verdict,detail\n";
    for (const auto& r : rs) {
        o << r.fault.id << ',' << r.fault.requirement << ',' << to_string(r.fault.proto)
          << ',' << r.fault.a << ',' << r.fault.b << ',' << r.fault.expect << ','
          << (r.dut.fault_observed ? "1" : "0") << ','
          << (r.ran ? (r.pass ? "PASS" : "FAIL") : "PLANNED") << ','
          << '"' << r.dut.detail << '"' << '\n';
    }
    return o.str();
}

inline std::string html_escape(const std::string& s) {
    std::string o;
    for (char c : s) switch (c) {
        case '&': o += "&amp;";  break; case '<': o += "&lt;";  break;
        case '>': o += "&gt;";   break; case '"': o += "&quot;"; break;
        default:  o += c;
    }
    return o;
}

// Self-contained HTML report (inline CSS, light/dark aware) — the presentable
// evidence artifact the plan's `report --format=html` calls for.
inline std::string report_html(const FaultCampaign& c,
                               const std::vector<ScenarioResult>& rs,
                               const CoverageTracker& cov) {
    Summary sm = summarize(rs, cov);
    char ts[64]; std::time_t t = std::time(nullptr);
    std::strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", std::localtime(&t));
    bool anyRan = false; for (auto& r : rs) if (r.ran) anyRan = true;

    std::ostringstream o;
    o << "<!doctype html><html><head><meta charset=\"utf-8\">"
         "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
         "<title>HardFuzz report — " << html_escape(c.name) << "</title><style>"
      "body{margin:0;font:15px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;background:#f6f7f9;color:#1a1d21}"
      "@media(prefers-color-scheme:dark){body{background:#14171a;color:#e6e8eb}}"
      ".wrap{max-width:960px;margin:0 auto;padding:32px 20px}"
      "header{display:flex;align-items:center;gap:14px;flex-wrap:wrap}"
      "h1{font-size:22px;margin:0;font-weight:650}h1 span{color:#7a828c;font-weight:500}"
      "h2{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:#7a828c;margin:30px 0 10px}"
      ".meta{color:#7a828c;font-size:13px;margin:8px 0 22px}"
      ".badge{padding:4px 12px;border-radius:999px;font-weight:650;font-size:13px}"
      ".pass{background:#e5f6ec;color:#12813f}.fail{background:#fdeaea;color:#c0342b}.plan{background:#eceef1;color:#5b6470}"
      "@media(prefers-color-scheme:dark){.pass{background:#123020;color:#5fd48b}.fail{background:#3a1c1a;color:#f0857c}.plan{background:#22262b;color:#9aa3ad}}"
      ".cards{display:flex;gap:12px;flex-wrap:wrap}"
      ".card{flex:1;min-width:120px;background:#fff;border:1px solid #e6e8eb;border-radius:10px;padding:14px 16px}"
      "@media(prefers-color-scheme:dark){.card{background:#1b1f24;border-color:#2a2f36}}"
      ".card b{display:block;font-size:26px;font-weight:680}.card span{color:#7a828c;font-size:13px}"
      ".card.ok b{color:#12813f}.card.bad b{color:#c0342b}"
      "table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #e6e8eb;border-radius:10px;overflow:hidden;font-size:14px}"
      "@media(prefers-color-scheme:dark){table{background:#1b1f24;border-color:#2a2f36}}"
      "th,td{text-align:left;padding:9px 12px;border-bottom:1px solid #eef0f2}"
      "@media(prefers-color-scheme:dark){th,td{border-color:#252a30}}"
      "th{font-size:11px;text-transform:uppercase;letter-spacing:.04em;color:#7a828c;background:#fafbfc}"
      "@media(prefers-color-scheme:dark){th{background:#171b1f}}tr:last-child td{border-bottom:0}"
      ".v{font-weight:650}.v.p{color:#12813f}.v.f{color:#c0342b}.v.n{color:#7a828c}"
      "code{font-family:ui-monospace,Menlo,monospace;font-size:13px}"
      ".bartrack{background:#eef0f2;border-radius:4px;height:8px}"
      "@media(prefers-color-scheme:dark){.bartrack{background:#252a30}}"
      ".bar{height:8px;border-radius:4px;background:#2f7ef0;min-width:2px}"
      "footer{color:#7a828c;font-size:12px;margin-top:26px}"
      "</style></head><body><div class=\"wrap\">";

    o << "<header><h1>HardFuzz <span>· " << html_escape(c.name) << "</span></h1>";
    if (!anyRan)            o << "<span class=\"badge plan\">PLANNED</span>";
    else if (sm.failed==0)  o << "<span class=\"badge pass\">ALL PASS</span>";
    else                    o << "<span class=\"badge fail\">" << sm.failed << " FAILED</span>";
    o << "</header>";
    o << "<div class=\"meta\">" << html_escape(c.target) << " &middot; " << html_escape(c.standard)
      << " &middot; generated " << ts << "</div>";

    o << "<div class=\"cards\">"
      << "<div class=\"card\"><b>" << sm.total  << "</b><span>scenarios</span></div>"
      << "<div class=\"card ok\"><b>" << sm.passed << "</b><span>passed</span></div>"
      << "<div class=\"card bad\"><b>" << sm.failed << "</b><span>failed</span></div>"
      << "<div class=\"card\"><b>" << sm.unique << "</b><span>unique tuples</span></div></div>";

    o << "<h2>Scenarios</h2><table><tr><th>ID</th><th>Req</th><th>Proto</th><th>Params</th>"
         "<th>Expected</th><th>Observed</th><th>Verdict</th></tr>";
    for (auto& r : rs) {
        auto pn = r.fault.param_names();
        const char* cls = !r.ran ? "n" : (r.pass ? "p" : "f");
        const char* txt = !r.ran ? "PLANNED" : (r.pass ? "PASS" : "FAIL");
        o << "<tr><td><code>" << html_escape(r.fault.id) << "</code></td><td>"
          << html_escape(r.fault.requirement) << "</td><td>" << to_string(r.fault.proto) << "</td><td>"
          << pn.first << "=" << r.fault.a << ", " << pn.second << "=" << r.fault.b << "</td><td>"
          << html_escape(r.fault.expect) << "</td><td>" << html_escape(r.dut.detail)
          << "</td><td class=\"v " << cls << "\">" << txt << "</td></tr>";
    }
    o << "</table>";

    o << "<h2>Coverage</h2><table><tr><th>Protocol</th><th>a</th><th>b</th><th>Hits</th><th></th></tr>";
    int maxhits = 1; for (auto& kv : cov.map()) if (kv.second > maxhits) maxhits = kv.second;
    for (auto& kv : cov.map()) {
        o << "<tr><td>" << to_string(kv.first.proto) << "</td><td>" << kv.first.a << "</td><td>"
          << kv.first.b << "</td><td>" << kv.second << "</td><td><div class=\"bartrack\">"
          << "<div class=\"bar\" style=\"width:" << (kv.second * 100 / maxhits) << "%\"></div></div></td></tr>";
    }
    o << "</table><footer>Generated by HardFuzz &middot; fault-injection evidence</footer></div></body></html>\n";
    return o.str();
}

inline bool write_file(const std::string& path, const std::string& content) {
    std::ofstream f(path);
    if (!f) return false;
    f << content;
    return true;
}

}  // namespace hardfuzz
