// hardfuzz/coverage.hpp — coverage bitmap + inverse-coverage scheduler.
#pragma once
#include "fault.hpp"
#include <map>
#include <vector>

namespace hardfuzz {

// Tracks how many times each (protocol, a, b) tuple has been faulted.
class CoverageTracker {
    std::map<CovKey, int> counts_;
public:
    void mark(const Fault& f) { counts_[key_of(f)]++; }
    int  count(const CovKey& k) const {
        auto it = counts_.find(k);
        return it == counts_.end() ? 0 : it->second;
    }
    int  count(const Fault& f) const { return count(key_of(f)); }
    std::size_t unique() const { return counts_.size(); }   // distinct tuples hit
    std::size_t total()  const {                            // total injections
        std::size_t s = 0; for (auto& kv : counts_) s += kv.second; return s;
    }
    const std::map<CovKey, int>& map() const { return counts_; }
};

// Coverage-guided scheduler: prefer the pending fault whose tuple has been hit least
// (highest priority = lowest current coverage). Re-evaluated each step, so duplicate
// tuples naturally deprioritize as they get exercised.
class Scheduler {
public:
    // Pick, among `pending` indices into `faults`, the one with the lowest coverage.
    // Ties break toward the earliest index (stable / deterministic).
    std::size_t next(const std::vector<Fault>& faults,
                     const std::vector<std::size_t>& pending,
                     const CoverageTracker& cov) const {
        std::size_t best = pending.front();
        int best_c = cov.count(faults[best]);
        for (std::size_t p : pending) {
            int c = cov.count(faults[p]);
            if (c < best_c) { best_c = c; best = p; }
        }
        return best;
    }
};

}  // namespace hardfuzz
