#ifndef SCR1_VCD_PER_TEST_H
#define SCR1_VCD_PER_TEST_H

#include <verilated.h>
#include <verilated_vcd_c.h>

#include <string>
#include <vector>
#include <cstdio>
#include <cstring>
#include <cctype>

#ifndef SCR1_STATE_TOP
#error "SCR1_STATE_TOP must be defined before including scr1_vcd_per_test.h"
#endif
#ifndef SCR1_STATE_MODEL
#error "SCR1_STATE_MODEL must be defined before including scr1_vcd_per_test.h"
#endif

#define SCR1_VCD_CAT_(a, b) a##b
#define SCR1_VCD_CAT(a, b)  SCR1_VCD_CAT_(a, b)
#define SCR1_VCD_CAT3(a, b, c) SCR1_VCD_CAT(SCR1_VCD_CAT(a, b), c)
#define SCR1_VCD_TB(t, name) \
    ((t)->rootp->SCR1_VCD_CAT(SCR1_STATE_TOP, SCR1_VCD_CAT(__DOT__, name)))
#define SCR1_VCD_PIPE(t, name) \
    ((t)->rootp->SCR1_VCD_CAT3(SCR1_STATE_TOP, __DOT__i_top__DOT__i_core_top__DOT__i_pipe_top__DOT__, name))

#define SCR1_VCD_EXIT_PC 0x000000F8u

typedef struct {
    VerilatedVcdC* tfp;
    int level;
    std::string dir;
    std::vector<std::string> tests;
    std::vector<std::string> used;
    size_t idx;
    int running_prev;
    int is_open;
    int pending;
    int seen_low;
    std::string pending_path;
    vluint64_t last_time;
} scr1_vcd_split_t;

static const char* scr1_vcd_plusarg(int argc, char** argv, const char* name) {
    size_t len = strlen(name);
    for (int i = 1; i < argc; ++i) {
        const char* arg = argv[i];
        if (arg[0] != '+') continue;
        if (strncmp(arg + 1, name, len) != 0) continue;
        if (arg[1 + len] == '=') return arg + 2 + len;
        if (arg[1 + len] == '\0') return arg + 1 + len;
    }
    return NULL;
}

static std::string scr1_vcd_basename(const std::string& path) {
    size_t slash = path.find_last_of("/\\");
    std::string name = (slash == std::string::npos) ? path : path.substr(slash + 1);
    size_t dot = name.find_last_of('.');
    if (dot != std::string::npos && dot != 0) name = name.substr(0, dot);

    for (size_t i = 0; i < name.size(); ++i) {
        unsigned char c = (unsigned char)name[i];
        if (!isalnum(c) && c != '.' && c != '_' && c != '-') name[i] = '_';
    }
    if (name.empty()) name = "test";
    return name;
}

static std::string scr1_vcd_unique(scr1_vcd_split_t* s, const std::string& base) {
    std::string name = base;
    int suffix = 2;
    for (;;) {
        int found = 0;
        for (size_t i = 0; i < s->used.size(); ++i) {
            if (s->used[i] == name) { found = 1; break; }
        }
        if (!found) break;
        name = base + "_" + std::to_string(suffix++);
    }
    s->used.push_back(name);
    return name;
}

static void scr1_vcd_load_tests(scr1_vcd_split_t* s, const char* path) {
    FILE* fd;
    char line[2048];
    if (path == NULL) return;
    fd = fopen(path, "r");
    if (fd == NULL) return;
    while (fgets(line, sizeof(line), fd) != NULL) {
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r' ||
                           line[len - 1] == ' '  || line[len - 1] == '\t')) {
            line[--len] = '\0';
        }
        if (len > 0) s->tests.push_back(std::string(line));
    }
    fclose(fd);
}

static void scr1_vcd_split_init(scr1_vcd_split_t* s, SCR1_STATE_MODEL* top,
                                int argc, char** argv) {
    const char* value;

    s->tfp = NULL;
    s->level = 99;
    s->dir = "build/trace";
    s->idx = 0;
    s->running_prev = 0;
    s->is_open = 0;
    s->pending = 0;
    s->seen_low = 0;
    s->last_time = 0;

    value = scr1_vcd_plusarg(argc, argv, "VCD_DIR");
    if (value != NULL && value[0] != '\0') s->dir = value;

    scr1_vcd_load_tests(s, scr1_vcd_plusarg(argc, argv, "test_info"));

    Verilated::traceEverOn(true);
#ifdef TRACE_LVLV
    s->level = TRACE_LVLV;
#endif
}

static void scr1_vcd_split_tick(scr1_vcd_split_t* s, SCR1_STATE_MODEL* top,
                                vluint64_t time) {
    int running = (int)(SCR1_VCD_TB(top, test_running)) & 1;
    int rst_n = (int)(SCR1_VCD_TB(top, rst_n)) & 1;
    uint32_t pc = (uint32_t)SCR1_VCD_PIPE(top, curr_pc);

    if (running && !s->running_prev) {
        if (s->is_open) {
            if (time > s->last_time) {
                s->tfp->dump(time);
                s->last_time = time;
            }
            s->tfp->close();
            delete s->tfp;
            s->tfp = NULL;
            s->is_open = 0;
        }

        std::string base;
        if (s->idx < s->tests.size()) base = scr1_vcd_basename(s->tests[s->idx]);
        else base = "test_" + std::to_string(s->idx);
        ++s->idx;

        std::string name = scr1_vcd_unique(s, base);
        s->pending_path = s->dir + "/" + name + ".vcd";
        s->pending = 1;
        s->seen_low = (rst_n == 0);
    }

    if (s->pending) {
        if (!rst_n) s->seen_low = 1;
        if (s->seen_low && rst_n) {
            s->tfp = new VerilatedVcdC;
            top->trace(s->tfp, s->level);
            s->tfp->open(s->pending_path.c_str());
            if (s->tfp->isOpen()) {
                s->is_open = 1;
                s->last_time = time;
                s->tfp->dump(time);
            } else {
                delete s->tfp;
                s->tfp = NULL;
            }
            s->pending = 0;
            s->seen_low = 0;
        } else if (!running && s->running_prev) {
            s->pending = 0;
            s->seen_low = 0;
        }
    }

    if (s->is_open) {
        if (time > s->last_time) {
            s->tfp->dump(time);
            s->last_time = time;
        }
        if (pc == SCR1_VCD_EXIT_PC) {
            s->tfp->close();
            delete s->tfp;
            s->tfp = NULL;
            s->is_open = 0;
        }
    }

    if (!running && s->running_prev && s->is_open) {
        s->tfp->close();
        delete s->tfp;
        s->tfp = NULL;
        s->is_open = 0;
    }

    s->running_prev = running;
}

static void scr1_vcd_split_finish(scr1_vcd_split_t* s, vluint64_t time) {
    if (s->is_open) {
        if (time > s->last_time) {
            s->tfp->dump(time);
        }
        s->tfp->close();
        s->is_open = 0;
    }
    if (s->tfp != NULL) {
        delete s->tfp;
        s->tfp = NULL;
    }
}

#endif
