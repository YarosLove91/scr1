#ifndef LOGGER_H
#define LOGGER_H

#include <cstdint>
#include <string>

//--------------------------------------------------------------------
// logger: colored console output for test results and messages.
// Colors are disabled by the NO_COLOR environment variable or
// enable_colors(false).
//--------------------------------------------------------------------
class logger
{
public:
    // Singleton access
    static logger &inst(void);

    // Color control
    void enable_colors(bool enable) { m_colors = enable; }
    bool colors_enabled(void) const { return m_colors; }

    // Generic messages
    void info(const std::string &msg) const;
    void warning(const std::string &msg) const;
    void error(const std::string &msg) const;

    // Test result reports
    void test_start(const std::string &test) const;
    void test_pass(uint64_t cycles, uint64_t sim_time_ns, uint64_t print_count) const;
    void test_fail(const std::string &reason) const;

private:
    logger(void);
    logger(const logger &) = delete;
    logger &operator=(const logger &) = delete;

    std::string paint(const std::string &msg, const char *color) const;

    bool m_colors;
};

#endif
