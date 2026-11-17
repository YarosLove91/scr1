#include <cstdlib>
#include <cstring>
#include <iostream>

#include "logger.h"

//--------------------------------------------------------------------
// ANSI color codes
//--------------------------------------------------------------------
#define COLOR_RED     "\033[31m"
#define COLOR_GREEN   "\033[32m"
#define COLOR_YELLOW  "\033[33m"
#define COLOR_RESET   "\033[0m"

//--------------------------------------------------------------------
// Message prefixes
//--------------------------------------------------------------------
#define PREFIX_PASS   "[+]"    // correct / pass
#define PREFIX_WARN   "[!]"    // attention
#define PREFIX_FAIL   "[-]"    // incorrect / failure

//--------------------------------------------------------------------
// Singleton access
//--------------------------------------------------------------------
logger &logger::inst(void)
{
    static logger s_logger;
    return s_logger;
}

//--------------------------------------------------------------------
// Construction: NO_COLOR environment variable disables colors
//--------------------------------------------------------------------
logger::logger(void)
{
    char *s = getenv("NO_COLOR");
    m_colors = !(s && strcmp(s, ""));
}

//--------------------------------------------------------------------
// paint: wrap message into color codes if enabled
//--------------------------------------------------------------------
std::string logger::paint(const std::string &msg, const char *color) const
{
    if (!m_colors)
        return msg;
    return std::string(color) + msg + COLOR_RESET;
}

//--------------------------------------------------------------------
// Generic messages
//--------------------------------------------------------------------
void logger::info(const std::string &msg) const
{
    std::cout << paint(PREFIX_PASS, COLOR_GREEN) << " " << msg << std::endl;
}

void logger::warning(const std::string &msg) const
{
    std::cout << paint(PREFIX_WARN, COLOR_YELLOW) << " " << msg << std::endl;
}

void logger::error(const std::string &msg) const
{
    std::cerr << paint(PREFIX_FAIL, COLOR_RED) << " " << msg << std::endl;
}

void logger::raw(const std::string &msg) const
{
    std::cout << msg << std::flush;
}

//--------------------------------------------------------------------
// Test result reports
//--------------------------------------------------------------------
void logger::test_start(const std::string &test) const
{
    info("Running: " + test);
}

void logger::test_pass(uint64_t cycles, uint64_t sim_time_ns, uint64_t print_count) const
{
    std::cout << "\n" << paint(std::string(PREFIX_PASS) + " Exit success!", COLOR_GREEN) << "\n"
              << "Cycles:\t"        << cycles      << "\n"
              << "Sim time:\t"      << sim_time_ns << " ns\n"
              << "Printed chars:\t" << print_count << std::endl;
}

void logger::test_fail(const std::string &reason) const
{
    std::cout << "\n" << paint(std::string(PREFIX_FAIL) + " Exit failure! " + reason, COLOR_RED)
              << std::endl;
}
