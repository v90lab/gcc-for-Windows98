// cpp_feature_probe.cpp
//
// Single-file probe of major C++ features that aren't already covered by the
// other smoke-cpp tests. Each probe is gated on a PROBE_ENABLE_* knob in
// cpp_feature_probe_config.hpp so the file is self-contained and the on/off
// state of every feature is documented in one place. Disabled probes report
// SKIP at runtime; enabled ones report PASS/FAIL with the failure reason.
//
// Self-contained: this .cpp + cpp_feature_probe_config.hpp, nothing else.
//
// Compile on Win98 with the native toolchain:
//   g++ -std=c++17 -pthread cpp_feature_probe.cpp -o probe.exe \
//       -Wl,--whole-archive -lwin98compat -Wl,--no-whole-archive
// Add -static-libgcc -static-libstdc++ for a fully-static binary (no
// libgcc_s_dw2-1.dll / libstdc++-6.dll alongside).
//
// In the smoke pipeline the CMake glob in smoke-cpp/CMakeLists.txt picks this
// file up automatically and builds both a dynamic and a _static variant; the
// cross-toolchain.cmake injects the -lwin98compat link flags. Both variants
// must pass pe-win98-check and run cleanly under Wine.
//
// Output: stdout, plus a copy in cpp_feature_probe.log in the cwd (so on Win98
// you can read the verdict even if the console scrolls past).

#include "cpp_feature_probe_config.hpp"

#include <iostream>
#include <fstream>
#include <string>
#include <stdexcept>

namespace {

struct ProbeOut {
    std::ofstream log;
    int pass = 0, fail = 0, skip = 0;
    ProbeOut() { log.open("cpp_feature_probe.log", std::ios::binary); }
    void emit(const std::string& line) {
        std::cout << line << std::endl;
        if (log) { log << line << "\n"; log.flush(); }
    }
};

ProbeOut g_out;

void report_pass(const char* tag) {
    ++g_out.pass;
    g_out.emit(std::string("  PASS  ") + tag);
}
void report_fail(const char* tag, const std::string& detail) {
    ++g_out.fail;
    g_out.emit(std::string("  FAIL  ") + tag + ": " + detail);
}
void report_skip(const char* tag, const char* why) {
    ++g_out.skip;
    g_out.emit(std::string("  SKIP  ") + tag + " (" + why + ")");
}

template <typename Fn>
void run_probe(const char* tag, Fn&& fn) {
    try {
        fn();
        report_pass(tag);
    } catch (const std::exception& e) {
        report_fail(tag, std::string("exception: ") + e.what());
    } catch (...) {
        report_fail(tag, "unknown exception");
    }
}

} // namespace

// ── Probe: std::shared_mutex (C++17) — pthread_rwlock_* via pthread9x ──────
#if PROBE_ENABLE_SHARED_MUTEX
#include <shared_mutex>
#include <mutex>
#include <thread>
#include <vector>
#include <atomic>
static void probe_shared_mutex() {
    run_probe("shared_mutex", []{
        std::shared_mutex m;
        int data = 0;
        { std::unique_lock<std::shared_mutex> lk(m); data = 42; }
        std::atomic<int> ok{0};
        std::vector<std::thread> rs;
        for (int i = 0; i < 4; ++i) {
            rs.emplace_back([&]{
                std::shared_lock<std::shared_mutex> lk(m);
                if (data == 42) ok.fetch_add(1);
            });
        }
        for (auto& t : rs) t.join();
        if (ok.load() != 4)
            throw std::runtime_error("readers saw=" + std::to_string(ok.load()));
    });
}
#else
static void probe_shared_mutex() { report_skip("shared_mutex", "disabled in config.hpp"); }
#endif

// ── Probe: std::condition_variable + sleep_for ──────────────────────────────
#if PROBE_ENABLE_CONDITION_VARIABLE
#include <condition_variable>
#include <mutex>
#include <thread>
#include <chrono>
static void probe_condition_variable() {
    run_probe("condition_variable", []{
        std::mutex m;
        std::condition_variable cv;
        bool ready = false;
        std::thread t([&]{
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            { std::lock_guard<std::mutex> lk(m); ready = true; }
            cv.notify_one();
        });
        std::unique_lock<std::mutex> lk(m);
        bool ok = cv.wait_for(lk, std::chrono::seconds(2), [&]{ return ready; });
        lk.unlock();
        t.join();
        if (!ok) throw std::runtime_error("wait_for timed out");
    });
}
#else
static void probe_condition_variable() { report_skip("condition_variable", "disabled in config.hpp"); }
#endif

// ── Probe: std::async / std::future / std::promise ─────────────────────────
#if PROBE_ENABLE_ASYNC
#include <future>
#include <chrono>
#include <thread>
static void probe_async() {
    run_probe("async/future/promise", []{
        auto fut = std::async(std::launch::async, []{ return 7 * 6; });
        if (fut.wait_for(std::chrono::seconds(2)) != std::future_status::ready)
            throw std::runtime_error("future not ready");
        if (fut.get() != 42)
            throw std::runtime_error("future value mismatch");
        std::promise<int> p;
        auto f2 = p.get_future();
        std::thread t([&]{ p.set_value(99); });
        t.join();
        if (f2.get() != 99) throw std::runtime_error("promise value mismatch");
    });
}
#else
static void probe_async() { report_skip("async/future/promise", "disabled in config.hpp"); }
#endif

// ── Probe: thread-safe static initializer ("magic statics") ────────────────
#if PROBE_ENABLE_MAGIC_STATICS
#include <thread>
#include <vector>
#include <atomic>
namespace {
std::atomic<int> g_init_count{0};
struct ProbeSingleton { ProbeSingleton() { g_init_count.fetch_add(1); } };
ProbeSingleton& get_probe_singleton() { static ProbeSingleton s; return s; }
}
static void probe_magic_statics() {
    run_probe("magic_statics", []{
        g_init_count.store(0);
        std::vector<std::thread> ts;
        for (int i = 0; i < 4; ++i) ts.emplace_back([]{ (void)get_probe_singleton(); });
        for (auto& t : ts) t.join();
        int n = g_init_count.load();
        if (n != 1)
            throw std::runtime_error("init ran " + std::to_string(n) + " times");
    });
}
#else
static void probe_magic_statics() { report_skip("magic_statics", "disabled in config.hpp"); }
#endif

// ── Probe: cross-thread exception propagation ──────────────────────────────
#if PROBE_ENABLE_CROSS_THREAD_EXCEPTION
#include <exception>
#include <thread>
static void probe_cross_thread_exception() {
    run_probe("cross_thread_exception", []{
        std::exception_ptr eptr;
        std::thread t([&]{
            try { throw std::runtime_error("from-worker"); }
            catch (...) { eptr = std::current_exception(); }
        });
        t.join();
        if (!eptr) throw std::runtime_error("eptr not captured");
        try {
            std::rethrow_exception(eptr);
            throw std::runtime_error("rethrow did not throw");
        } catch (const std::runtime_error& e) {
            if (std::string(e.what()) != "from-worker")
                throw std::runtime_error(std::string("wrong what(): ") + e.what());
        }
    });
}
#else
static void probe_cross_thread_exception() { report_skip("cross_thread_exception", "disabled in config.hpp"); }
#endif

// ── Probe: std::chrono clocks ──────────────────────────────────────────────
#if PROBE_ENABLE_CHRONO
#include <chrono>
#include <thread>
static void probe_chrono() {
    run_probe("chrono", []{
        auto sc1 = std::chrono::system_clock::now();
        auto st1 = std::chrono::steady_clock::now();
        std::this_thread::sleep_for(std::chrono::milliseconds(60));
        auto sc2 = std::chrono::system_clock::now();
        auto st2 = std::chrono::steady_clock::now();
        auto sc_ms = std::chrono::duration_cast<std::chrono::milliseconds>(sc2 - sc1).count();
        auto st_ms = std::chrono::duration_cast<std::chrono::milliseconds>(st2 - st1).count();
        if (sc_ms < 30) throw std::runtime_error("system_clock delta=" + std::to_string(sc_ms) + "ms");
        if (st_ms < 30) throw std::runtime_error("steady_clock delta=" + std::to_string(st_ms) + "ms");
        // Sanity-check the wall clock isn't pre-2020 (would mean Win98 RTC not set,
        // or our GetSystemTimePreciseAsFileTime shim is misreporting).
        auto epoch_s = std::chrono::duration_cast<std::chrono::seconds>(sc1.time_since_epoch()).count();
        if (epoch_s < 1577836800LL)
            throw std::runtime_error("system_clock epoch implausibly old: " + std::to_string(epoch_s));
    });
}
#else
static void probe_chrono() { report_skip("chrono", "disabled in config.hpp"); }
#endif

// ── Probe: std::atomic concurrent fetch_add ────────────────────────────────
#if PROBE_ENABLE_ATOMIC
#include <atomic>
#include <thread>
#include <vector>
static void probe_atomic() {
    run_probe("atomic", []{
        std::atomic<int> counter{0};
        std::vector<std::thread> ts;
        for (int i = 0; i < 4; ++i)
            ts.emplace_back([&]{ for (int j = 0; j < 1000; ++j) counter.fetch_add(1); });
        for (auto& t : ts) t.join();
        int n = counter.load();
        if (n != 4000) throw std::runtime_error("counter=" + std::to_string(n));
    });
}
#else
static void probe_atomic() { report_skip("atomic", "disabled in config.hpp"); }
#endif

// ── Probe: std::regex ──────────────────────────────────────────────────────
#if PROBE_ENABLE_REGEX
#include <regex>
static void probe_regex() {
    run_probe("regex", []{
        std::regex re("([a-z]+)=([0-9]+)");
        std::smatch m;
        std::string s = "answer=42";
        if (!std::regex_search(s, m, re))
            throw std::runtime_error("no match");
        if (m[1].str() != "answer")
            throw std::runtime_error("group1='" + m[1].str() + "'");
        if (m[2].str() != "42")
            throw std::runtime_error("group2='" + m[2].str() + "'");
    });
}
#else
static void probe_regex() { report_skip("regex", "disabled in config.hpp"); }
#endif

// ── Probe: std::unordered_map ──────────────────────────────────────────────
#if PROBE_ENABLE_UNORDERED_MAP
#include <unordered_map>
static void probe_unordered_map() {
    run_probe("unordered_map", []{
        std::unordered_map<std::string, int> um;
        for (int i = 0; i < 100; ++i) um["key" + std::to_string(i)] = i;
        if (um.size() != 100)
            throw std::runtime_error("size=" + std::to_string(um.size()));
        if (um["key42"] != 42) throw std::runtime_error("key42 lookup");
        um.erase("key50");
        if (um.find("key50") != um.end()) throw std::runtime_error("erase did not take");
    });
}
#else
static void probe_unordered_map() { report_skip("unordered_map", "disabled in config.hpp"); }
#endif

// ── Probe: std::stringstream ───────────────────────────────────────────────
#if PROBE_ENABLE_STRINGSTREAM
#include <sstream>
static void probe_stringstream() {
    run_probe("stringstream", []{
        std::ostringstream os;
        os << "n=" << 42 << " d=" << 3.5;
        std::string out = os.str();
        if (out != "n=42 d=3.5") throw std::runtime_error("formatted='" + out + "'");
        std::istringstream is("123 4.5 hello");
        int n; double d; std::string s;
        is >> n >> d >> s;
        if (n != 123 || d != 4.5 || s != "hello")
            throw std::runtime_error("parsed n=" + std::to_string(n)
                                   + " d=" + std::to_string(d) + " s='" + s + "'");
    });
}
#else
static void probe_stringstream() { report_skip("stringstream", "disabled in config.hpp"); }
#endif

// ── Probe: std::shared_ptr + std::weak_ptr ────────────────────────────────
#if PROBE_ENABLE_SHARED_PTR
#include <memory>
#include <atomic>
namespace {
std::atomic<int> g_node_destroyed{0};
struct ProbeNode {
    int v;
    std::shared_ptr<ProbeNode> next;
    explicit ProbeNode(int x) : v(x) {}
    ~ProbeNode() { g_node_destroyed.fetch_add(1); }
};
}
static void probe_shared_ptr() {
    run_probe("shared_ptr", []{
        g_node_destroyed.store(0);
        {
            auto a = std::make_shared<ProbeNode>(1);
            auto b = std::make_shared<ProbeNode>(2);
            a->next = b;
        }
        int destroyed = g_node_destroyed.load();
        if (destroyed != 2)
            throw std::runtime_error("destroyed=" + std::to_string(destroyed));
        auto sp = std::make_shared<int>(99);
        std::weak_ptr<int> wp = sp;
        if (wp.expired()) throw std::runtime_error("wp expired while sp held");
        if (auto l = wp.lock(); !l || *l != 99) throw std::runtime_error("wp.lock value");
        sp.reset();
        if (!wp.expired()) throw std::runtime_error("wp not expired after reset");
    });
}
#else
static void probe_shared_ptr() { report_skip("shared_ptr", "disabled in config.hpp"); }
#endif

// ── Probe: std::function + lambda capture ─────────────────────────────────
#if PROBE_ENABLE_FUNCTION
#include <functional>
#include <memory>
static void probe_function() {
    run_probe("function", []{
        int cap = 100;
        std::function<int(int)> f = [cap](int x) { return x + cap; };
        if (f(5) != 105) throw std::runtime_error("f(5)=" + std::to_string(f(5)));
        f = [](int x) { return x * 2; };
        if (f(7) != 14) throw std::runtime_error("reassigned f(7)=" + std::to_string(f(7)));
        auto sp = std::make_shared<int>(42);
        std::function<int()> g = [sp]{ return *sp; };
        if (g() != 42) throw std::runtime_error("shared-capture g()=" + std::to_string(g()));
    });
}
#else
static void probe_function() { report_skip("function", "disabled in config.hpp"); }
#endif

// ── Probe: std::optional + std::variant + std::string_view (C++17) ────────
#if PROBE_ENABLE_CPP17_VOCAB
#include <optional>
#include <variant>
#include <string_view>
static void probe_cpp17_vocab() {
    run_probe("cpp17_vocab", []{
        std::optional<int> o;
        if (o) throw std::runtime_error("empty optional truthy");
        o = 42;
        if (!o || *o != 42) throw std::runtime_error("optional value");

        std::variant<int, std::string> v = std::string("hi");
        if (v.index() != 1) throw std::runtime_error("variant index=" + std::to_string(v.index()));
        if (std::get<std::string>(v) != "hi") throw std::runtime_error("variant get");
        bool threw = false;
        try { (void)std::get<int>(v); }
        catch (const std::bad_variant_access&) { threw = true; }
        if (!threw) throw std::runtime_error("bad_variant_access not thrown");

        std::string s = "hello world";
        std::string_view sv(s.data() + 6, 5);
        if (sv != "world") throw std::runtime_error("string_view content");
    });
}
#else
static void probe_cpp17_vocab() { report_skip("cpp17_vocab", "disabled in config.hpp"); }
#endif

// ── Probe: RTTI (dynamic_cast + typeid) ───────────────────────────────────
#if PROBE_ENABLE_RTTI
#include <typeinfo>
#include <memory>
namespace {
struct ProbeBase { virtual ~ProbeBase() = default; };
struct ProbeDerived : ProbeBase { int x = 42; };
struct ProbeOther : ProbeBase {};
}
static void probe_rtti() {
    run_probe("rtti", []{
        std::unique_ptr<ProbeBase> p(new ProbeDerived);
        auto* d = dynamic_cast<ProbeDerived*>(p.get());
        if (!d || d->x != 42) throw std::runtime_error("dynamic_cast to Derived");
        auto* o = dynamic_cast<ProbeOther*>(p.get());
        if (o) throw std::runtime_error("dynamic_cast to wrong type returned non-null");
        std::string name = typeid(*p).name();
        if (name.find("Derived") == std::string::npos)
            throw std::runtime_error("typeid name='" + name + "'");
    });
}
#else
static void probe_rtti() { report_skip("rtti", "disabled in config.hpp"); }
#endif

// ── Probe: std::random_device (DEFAULT-OFF: bcrypt import) ────────────────
#if PROBE_ENABLE_RANDOM_DEVICE
#include <random>
static void probe_random_device() {
    run_probe("random_device", []{
        std::random_device rd;
        std::mt19937 gen(rd());
        std::uniform_int_distribution<int> dist(1, 100);
        int sum = 0;
        for (int i = 0; i < 10; ++i) {
            int x = dist(gen);
            if (x < 1 || x > 100)
                throw std::runtime_error("dist out of range: " + std::to_string(x));
            sum += x;
        }
        if (sum < 10 || sum > 1000)
            throw std::runtime_error("sum implausible: " + std::to_string(sum));
    });
}
#else
static void probe_random_device() { report_skip("random_device", "disabled in config.hpp (bcrypt.dll import)"); }
#endif

// ── Probe: std::filesystem (DEFAULT-OFF: Vista+ wide APIs) ────────────────
#if PROBE_ENABLE_FILESYSTEM
#include <filesystem>
#include <fstream>
static void probe_filesystem() {
    run_probe("filesystem", []{
        namespace fs = std::filesystem;
        auto dir = fs::temp_directory_path() / "cpp_probe_fs";
        fs::remove_all(dir);
        fs::create_directories(dir);
        { std::ofstream(dir / "f.txt") << "hi"; }
        bool found = false;
        for (auto& e : fs::directory_iterator(dir))
            if (e.path().filename() == "f.txt") found = true;
        if (!found) throw std::runtime_error("directory_iterator missed file");
        if (fs::file_size(dir / "f.txt") != 2)
            throw std::runtime_error("file_size mismatch");
        fs::remove_all(dir);
    });
}
#else
static void probe_filesystem() { report_skip("filesystem", "disabled in config.hpp (Vista+ wide-API imports)"); }
#endif

// ── main ──────────────────────────────────────────────────────────────────
int main() {
    g_out.emit("=== C++ feature probe ===");
    g_out.emit(std::string("compiler: ") + __VERSION__);
#ifdef __MINGW32__
    g_out.emit("toolchain: mingw-w64 / i686-w64-mingw32");
#endif
#ifdef __GLIBCXX__
    g_out.emit("libstdc++ date: " + std::to_string(__GLIBCXX__));
#endif
    g_out.emit("");

    probe_shared_mutex();
    probe_condition_variable();
    probe_async();
    probe_magic_statics();
    probe_cross_thread_exception();
    probe_chrono();
    probe_atomic();
    probe_regex();
    probe_unordered_map();
    probe_stringstream();
    probe_shared_ptr();
    probe_function();
    probe_cpp17_vocab();
    probe_rtti();
    probe_random_device();
    probe_filesystem();

    g_out.emit("");
    g_out.emit("=== summary: " + std::to_string(g_out.pass) + " pass, "
               + std::to_string(g_out.fail) + " fail, "
               + std::to_string(g_out.skip) + " skip ===");
    return g_out.fail > 0 ? 1 : 0;
}
