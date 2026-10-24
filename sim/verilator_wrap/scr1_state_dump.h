#ifndef SCR1_STATE_DUMP_H
#define SCR1_STATE_DUMP_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

#ifdef STATE_DUMP

#include <verilated.h>

#include <string>
#include <vector>
#include <cctype>

#ifndef SCR1_STATE_TOP
#error "SCR1_STATE_TOP must be defined before including scr1_state_dump.h"
#endif
#ifndef SCR1_STATE_MODEL
#error "SCR1_STATE_MODEL must be defined before including scr1_state_dump.h"
#endif

#ifndef SCR1_STATE_DEFAULT_FILE
#define SCR1_STATE_DEFAULT_FILE "scr1_final_state.txt"
#endif
#ifndef SCR1_STATE_DEFAULT_FINAL_PC
#define SCR1_STATE_DEFAULT_FINAL_PC 0x000000F8u
#endif
#ifndef SCR1_STATE_MISA
#define SCR1_STATE_MISA 0x40001104u
#endif

#define SCR1_STATE_NO_PC    0xFFFFFFFFu
#define SCR1_STATE_BUF      1024
#define SCR1_STATE_CAT_(a, b)       a##b
#define SCR1_STATE_CAT(a, b)        SCR1_STATE_CAT_(a, b)
#define SCR1_STATE_CAT3(a, b, c)    SCR1_STATE_CAT(SCR1_STATE_CAT(a, b), c)
#define SCR1_STATE_PIPE(t, name) \
    ((t)->rootp->SCR1_STATE_CAT3(SCR1_STATE_TOP, __DOT__i_top__DOT__i_core_top__DOT__i_pipe_top__DOT__, name))
#define SCR1_STATE_TB(t, name) \
    ((t)->rootp->SCR1_STATE_CAT(SCR1_STATE_TOP, SCR1_STATE_CAT(__DOT__, name)))

typedef struct {
    uint32_t gpr[32];
    uint32_t mstatus;
    uint32_t mie;
    uint32_t mtvec;
    uint32_t mscratch;
    uint32_t mepc;
    uint32_t mcause;
    uint32_t mtval;
    uint32_t mip;
    uint32_t mhartid;
    uint64_t mcycle;
    uint64_t minstret;
    uint32_t pc;
    uint64_t time;
} scr1_state_snapshot_t;

typedef struct {
    scr1_state_snapshot_t snap;
    int                   valid;
} scr1_state_entry_t;

static char scr1_state_file[SCR1_STATE_BUF] = SCR1_STATE_DEFAULT_FILE;
static char scr1_state_dir[SCR1_STATE_BUF] = "build/trace";
static char scr1_state_results[SCR1_STATE_BUF];
static uint32_t scr1_state_final_pc = SCR1_STATE_DEFAULT_FINAL_PC;
static uint64_t scr1_state_max_cycles = 0;
static volatile sig_atomic_t scr1_state_sigint = 0;
static volatile sig_atomic_t scr1_state_signal_num = 0;
static volatile sig_atomic_t scr1_state_timeout = 0;
static int scr1_state_have_snapshot = 0;
static scr1_state_snapshot_t scr1_state_snapshot;
static std::vector<std::string> scr1_state_tests;
static std::vector<scr1_state_entry_t> scr1_state_entries;
static size_t scr1_state_test_idx = 0;
static int scr1_state_running_prev = 0;
static std::vector<std::string> scr1_state_result_lines;

static const char* scr1_state_plusarg(int argc, char** argv, const char* name) {
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

static std::string scr1_state_basename(const std::string& path) {
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

static void scr1_state_load_tests(const char* path) {
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
        if (len > 0) scr1_state_tests.push_back(std::string(line));
    }
    fclose(fd);
}

static void scr1_state_load_results(void) {
    FILE* fd;
    char line[2048];
    if (scr1_state_results[0] == '\0') return;
    fd = fopen(scr1_state_results, "r");
    if (fd == NULL) return;
    while (fgets(line, sizeof(line), fd) != NULL) {
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
            line[--len] = '\0';
        }
        if (len > 0) scr1_state_result_lines.push_back(std::string(line));
    }
    fclose(fd);
}

static void scr1_state_signal_handler(int sig) {
    scr1_state_signal_num = sig;
    scr1_state_sigint = 1;
}

static void scr1_state_dump_init(int argc, char** argv) {
    const char* value;
    struct sigaction sa;

    value = scr1_state_plusarg(argc, argv, "STATE_FILE");
    if (value != NULL && value[0] != '\0') {
        strncpy(scr1_state_file, value, sizeof(scr1_state_file) - 1);
        scr1_state_file[sizeof(scr1_state_file) - 1] = '\0';
    }

    value = scr1_state_plusarg(argc, argv, "STATE_DIR");
    if (value != NULL && value[0] != '\0') {
        strncpy(scr1_state_dir, value, sizeof(scr1_state_dir) - 1);
        scr1_state_dir[sizeof(scr1_state_dir) - 1] = '\0';
    }

    value = scr1_state_plusarg(argc, argv, "FINAL_PC");
    if (value != NULL && value[0] != '\0') {
        if ((strcmp(value, "none") == 0) || (strcmp(value, "off") == 0)) {
            scr1_state_final_pc = SCR1_STATE_NO_PC;
        } else {
            scr1_state_final_pc = (uint32_t)strtoul(value, NULL, 0);
        }
    }

    value = scr1_state_plusarg(argc, argv, "MAX_CYCLES");
    if (value != NULL && value[0] != '\0') {
        scr1_state_max_cycles = (uint64_t)strtoull(value, NULL, 0);
    }

    value = scr1_state_plusarg(argc, argv, "test_results");
    if (value != NULL && value[0] != '\0') {
        strncpy(scr1_state_results, value, sizeof(scr1_state_results) - 1);
        scr1_state_results[sizeof(scr1_state_results) - 1] = '\0';
    }

    scr1_state_load_tests(scr1_state_plusarg(argc, argv, "test_info"));
    scr1_state_entries.resize(scr1_state_tests.size());
    for (size_t i = 0; i < scr1_state_entries.size(); ++i) {
        scr1_state_entries[i].valid = 0;
    }
    scr1_state_test_idx = 0;
    scr1_state_running_prev = 0;

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = scr1_state_signal_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

static uint32_t scr1_state_gpr_word(SCR1_STATE_MODEL* top, int idx) {
    if (idx == 0) return 0;
    return (uint32_t)SCR1_STATE_PIPE(top, i_pipe_mprf__DOT__mprf_int)[31 - idx];
}

static void scr1_state_capture(SCR1_STATE_MODEL* top, vluint64_t time,
                               scr1_state_snapshot_t* s) {
    for (int idx = 0; idx < 32; ++idx) {
        s->gpr[idx] = scr1_state_gpr_word(top, idx);
    }

    s->mstatus = ((uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mstatus_mie_ff) << 3)
               | ((uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mstatus_mpie_ff) << 7)
               | (3u << 11);
    s->mie = ((uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mie_msie_ff) << 3)
           | ((uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mie_mtie_ff) << 7)
           | ((uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mie_meie_ff) << 11);
    s->mtvec = ((uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mtvec_base) << 6)
             | ((uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mtvec_mode) & 1u);
    s->mscratch = (uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mscratch_ff);
    s->mepc = (uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mepc_ff) << 2;
    s->mcause = ((uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mcause_i_ff) << 31)
              | ((uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mcause_ec_ff) & 0xFu);
    s->mtval = (uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mtval_ff);
    s->mip = ((uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mip_msip) << 3)
           | ((uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mip_mtip) << 7)
           | ((uint32_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mip_meip) << 11);
    s->mhartid = (uint32_t)SCR1_STATE_TB(top, fuse_mhartid);
    s->mcycle = (uint64_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_mcycle);
    s->minstret = (uint64_t)SCR1_STATE_PIPE(top, i_pipe_csr__DOT__csr_minstret);
    s->pc = (uint32_t)SCR1_STATE_PIPE(top, curr_pc);
    s->time = (uint64_t)time;
}

static void scr1_state_dump_poll(SCR1_STATE_MODEL* top, vluint64_t time) {
    int running;

    if (scr1_state_max_cycles != 0 && ((uint64_t)time / 10u) > scr1_state_max_cycles) {
        scr1_state_timeout = 1;
        return;
    }

    running = (int)(SCR1_STATE_TB(top, test_running)) & 1;

    if (running && !scr1_state_running_prev) {
        if (scr1_state_test_idx < scr1_state_entries.size()) {
            scr1_state_entries[scr1_state_test_idx].valid = 0;
        }
    }

    if ((scr1_state_final_pc != SCR1_STATE_NO_PC) &&
        ((uint32_t)SCR1_STATE_TB(top, rst_n) != 0) &&
        ((uint32_t)SCR1_STATE_PIPE(top, curr_pc) == scr1_state_final_pc)) {
        if (scr1_state_test_idx < scr1_state_entries.size()) {
            scr1_state_capture(top, time, &scr1_state_entries[scr1_state_test_idx].snap);
            scr1_state_entries[scr1_state_test_idx].valid = 1;
        } else {
            scr1_state_capture(top, time, &scr1_state_snapshot);
            scr1_state_have_snapshot = 1;
        }
    }

    if (!running && scr1_state_running_prev) {
        if (scr1_state_test_idx < scr1_state_entries.size()) {
            if (!scr1_state_entries[scr1_state_test_idx].valid) {
                scr1_state_capture(top, time, &scr1_state_entries[scr1_state_test_idx].snap);
                scr1_state_entries[scr1_state_test_idx].valid = 1;
            }
            scr1_state_test_idx++;
        }
    }

    scr1_state_running_prev = running;
}

static const char* scr1_state_status_for(size_t idx) {
    if (idx < scr1_state_result_lines.size()) {
        if (strstr(scr1_state_result_lines[idx].c_str(), "__FAIL") != NULL) return "FAIL";
        if (strstr(scr1_state_result_lines[idx].c_str(), "PASS") != NULL) return "PASS";
    }
    return "PASS";
}

static int scr1_state_write(const char* path, const scr1_state_snapshot_t* s,
                            const char* status) {
    static const char* abi_names[32] = {
        "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
        "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
        "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
        "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"
    };
    FILE* fd = fopen(path, "w");

    if (fd == NULL) {
        fprintf(stderr, "ERROR: cannot open state file '%s'\n", path);
        return 1;
    }

    fprintf(fd, "# SCR1 final architectural state\n");
    fprintf(fd, "# sim_status: %s\n", status);
    fprintf(fd, "# time: %llu\n", (unsigned long long)s->time);
    fprintf(fd, "# pc: 0x%08x\n", s->pc);

    for (int row = 0; row < 8; ++row) {
        for (int col = 0; col < 4; ++col) {
            int idx = row * 4 + col;
            fprintf(fd, "%4s: 0x%08x", abi_names[idx], s->gpr[idx]);
        }
        fprintf(fd, "\n");
    }

    fprintf(fd, "priv M\n");
    fprintf(fd, "# CSR\n");
    fprintf(fd, "%-9s 0x%08x\n", "mstatus", s->mstatus);
    fprintf(fd, "%-9s 0x%08x\n", "misa", SCR1_STATE_MISA);
    fprintf(fd, "%-9s 0x%08x\n", "mie", s->mie);
    fprintf(fd, "%-9s 0x%08x\n", "mtvec", s->mtvec);
    fprintf(fd, "%-9s 0x%08x\n", "mscratch", s->mscratch);
    fprintf(fd, "%-9s 0x%08x\n", "mepc", s->mepc);
    fprintf(fd, "%-9s 0x%08x\n", "mcause", s->mcause);
    fprintf(fd, "%-9s 0x%08x\n", "mtval", s->mtval);
    fprintf(fd, "%-9s 0x%08x\n", "mip", s->mip);
    fprintf(fd, "%-9s 0x%08x\n", "mhartid", s->mhartid);
    fprintf(fd, "%-9s 0x%08x\n", "mcycle", (uint32_t)s->mcycle);
    fprintf(fd, "%-9s 0x%08x\n", "mcycleh", (uint32_t)(s->mcycle >> 32));
    fprintf(fd, "%-9s 0x%08x\n", "minstret", (uint32_t)s->minstret);
    fprintf(fd, "%-9s 0x%08x\n", "minstreth", (uint32_t)(s->minstret >> 32));

    if (fclose(fd) != 0) {
        fprintf(stderr, "ERROR: cannot write state file '%s'\n", path);
        return 1;
    }
    return 0;
}

static int scr1_state_dump_finish(SCR1_STATE_MODEL* top, vluint64_t time) {
    const char* status;
    int rc = 0;

    if (scr1_state_test_idx < scr1_state_entries.size() &&
        !scr1_state_entries[scr1_state_test_idx].valid) {
        scr1_state_capture(top, time, &scr1_state_entries[scr1_state_test_idx].snap);
        scr1_state_entries[scr1_state_test_idx].valid = 1;
    }

    scr1_state_load_results();

    if (!scr1_state_tests.empty()) {
        size_t last = scr1_state_tests.size() - 1;
        for (size_t i = 0; i < scr1_state_tests.size(); ++i) {
            std::string path;
            std::string base;
            const char* entry_status;

            if (!scr1_state_entries[i].valid) continue;
            base = scr1_state_basename(scr1_state_tests[i]);
            path = std::string(scr1_state_dir) + "/" + base + "_state.txt";
            entry_status = scr1_state_status_for(i);
            if (i == last && scr1_state_sigint) {
                entry_status = (scr1_state_signal_num == SIGTERM) ? "SIGTERM" : "SIGINT";
            } else if (i == last && scr1_state_timeout) {
                entry_status = "TIMEOUT";
            }
            rc |= scr1_state_write(path.c_str(), &scr1_state_entries[i].snap, entry_status);
        }
        return rc;
    }

    if (!scr1_state_have_snapshot) {
        scr1_state_capture(top, time, &scr1_state_snapshot);
        scr1_state_have_snapshot = 1;
    }
    status = scr1_state_status_for(0);
    if (scr1_state_sigint) {
        status = (scr1_state_signal_num == SIGTERM) ? "SIGTERM" : "SIGINT";
    } else if (scr1_state_timeout) {
        status = "TIMEOUT";
    }
    return scr1_state_write(scr1_state_file, &scr1_state_snapshot, status);
}

static int scr1_state_dump_should_stop(void) {
    return (scr1_state_sigint != 0) || (scr1_state_timeout != 0);
}

#else

#define scr1_state_dump_init(argc, argv)        ((void)0)
#define scr1_state_dump_poll(top, time)         ((void)0)
#define scr1_state_dump_finish(top, time)       (0)
#define scr1_state_dump_should_stop()           (0)

#endif

#endif
