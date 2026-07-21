// hardfuzz/json.hpp — minimal JSON parser (the subset campaign files need) + a loader.
#pragma once
#include "campaign.hpp"
#include <cctype>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace hardfuzz {

struct JsonValue {
    enum Type { Null, Bool, Num, Str, Arr, Obj } type = Null;
    bool        b = false;
    double      num = 0;
    std::string str;
    std::vector<JsonValue> arr;
    std::vector<std::pair<std::string, JsonValue>> obj;

    const JsonValue* find(const std::string& k) const {
        for (auto& kv : obj) if (kv.first == k) return &kv.second;
        return nullptr;
    }
    std::string as_str(const std::string& d = "") const { return type == Str ? str : d; }
    int         as_int(int d = 0) const { return type == Num ? (int)num : d; }
};

class JsonParser {
    const std::string& s; std::size_t i = 0;
public:
    explicit JsonParser(const std::string& str) : s(str) {}
    JsonValue parse() { skip(); JsonValue v = value(); return v; }
private:
    void skip() { while (i < s.size() && (s[i]==' '||s[i]=='\t'||s[i]=='\n'||s[i]=='\r')) i++; }
    [[noreturn]] void err(const char* m) { throw std::runtime_error(std::string("json: ") + m); }
    char peek() { return i < s.size() ? s[i] : '\0'; }

    JsonValue value() {
        skip();
        char c = peek();
        if (c == '{') return object();
        if (c == '[') return array();
        if (c == '"') { JsonValue v; v.type = JsonValue::Str; v.str = str_(); return v; }
        if (c == 't' || c == 'f') return boolean();
        if (c == 'n') { i += 4; return JsonValue{}; }
        return number();
    }
    std::string str_() {
        if (peek() != '"') err("expected string"); i++;
        std::string o;
        while (i < s.size() && s[i] != '"') {
            char c = s[i++];
            if (c == '\\' && i < s.size()) {
                char e = s[i++];
                switch (e) { case 'n':o+='\n';break; case 't':o+='\t';break;
                             case '"':o+='"';break; case '\\':o+='\\';break;
                             case '/':o+='/';break; default:o+=e; }
            } else o += c;
        }
        if (peek() != '"') err("unterminated string"); i++;
        return o;
    }
    JsonValue boolean() {
        JsonValue v; v.type = JsonValue::Bool;
        if (s.compare(i, 4, "true") == 0) { v.b = true;  i += 4; }
        else                              { v.b = false; i += 5; }
        return v;
    }
    JsonValue number() {
        std::size_t start = i;
        if (peek() == '-') i++;
        while (i < s.size() && (std::isdigit((unsigned char)s[i]) || s[i]=='.' ||
               s[i]=='e' || s[i]=='E' || s[i]=='+' || s[i]=='-')) i++;
        JsonValue v; v.type = JsonValue::Num;
        v.num = std::strtod(s.substr(start, i - start).c_str(), nullptr);
        return v;
    }
    JsonValue array() {
        JsonValue v; v.type = JsonValue::Arr; i++; skip();
        if (peek() == ']') { i++; return v; }
        while (true) {
            v.arr.push_back(value()); skip();
            char c = peek();
            if (c == ',') { i++; continue; }
            if (c == ']') { i++; break; }
            err("expected , or ]");
        }
        return v;
    }
    JsonValue object() {
        JsonValue v; v.type = JsonValue::Obj; i++; skip();
        if (peek() == '}') { i++; return v; }
        while (true) {
            skip(); std::string k = str_(); skip();
            if (peek() != ':') err("expected :"); i++;
            v.obj.push_back({k, value()}); skip();
            char c = peek();
            if (c == ',') { i++; continue; }
            if (c == '}') { i++; break; }
            err("expected , or }");
        }
        return v;
    }
};

inline JsonValue json_parse(const std::string& s) { return JsonParser(s).parse(); }

// Build a FaultCampaign from parsed JSON. Each fault accepts either role-named params
// (spi: frame/bit, i2c: byte/stretch_cycles, can: bit/width) or generic "a"/"b".
inline FaultCampaign campaign_from_json(const JsonValue& j) {
    FaultCampaign c;
    if (auto* n = j.find("name"))     c.name     = n->as_str();
    if (auto* t = j.find("target"))   c.target   = t->as_str();
    if (auto* s = j.find("standard")) c.standard = s->as_str();
    if (auto* fs = j.find("faults")) {
        for (auto& e : fs->arr) {
            Fault f;
            if (auto* p = e.find("id"))          f.id = p->as_str();
            Protocol pr = Protocol::Spi;
            if (auto* p = e.find("protocol"))    protocol_from(p->as_str(), pr);
            f.proto = pr;
            auto pn = f.param_names();
            if (auto* p = e.find(pn.first))      f.a = p->as_int();
            else if (auto* p = e.find("a"))      f.a = p->as_int();
            if (auto* p = e.find(pn.second))     f.b = p->as_int();
            else if (auto* p = e.find("b"))      f.b = p->as_int();
            if (auto* p = e.find("expect"))      f.expect = p->as_str();
            if (auto* p = e.find("requirement")) f.requirement = p->as_str();
            c.faults.push_back(f);
        }
    }
    return c;
}

}  // namespace hardfuzz
