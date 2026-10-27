/* app.cpp — задачи FreeRTOS и сценарий дифференциального стенда */
#include <FreeRTOS.h>
#include <task.h>
#include <queue.h>

#include "console.h"
#include "app.hpp"

extern "C" void sc_exit(unsigned result, unsigned res0, unsigned res1,
                        unsigned res2, unsigned res3) __attribute__((noreturn));

namespace {

struct Msg {
    uint32_t tag;
    uint32_t v0;
    uint32_t v1;
};

enum { TAG_A = 1u, TAG_T = 2u, TAG_B = 3u };

FixedMatrix  mx;
RingBuffer<uint32_t, 64> ring;
Lcg lcgA(0x1234567u);
Lcg lcgB(0x7654321u);

QueueHandle_t qTrig;
QueueHandle_t qRep;
QueueHandle_t qTokB;

/* ---------- FixedMatrix ---------- */
}  // namespace

void FixedMatrix::identity()
{
    for (int r = 0; r < 4; ++r) {
        for (int c = 0; c < 4; ++c) {
            m_[r][c] = (r == c) ? 256 : 0;   /* 1.0 в Q8 */
        }
    }
}

void FixedMatrix::step(uint32_t k)
{
    int32_t t[4][4];
    for (int r = 0; r < 4; ++r) {
        for (int c = 0; c < 4; ++c) {
            int32_t acc = 0;
            for (int i = 0; i < 4; ++i) {
                acc += (m_[r][i] * m_[i][c]) >> 8;
            }
            t[r][c] = acc;
        }
    }
    for (int r = 0; r < 4; ++r) {
        for (int c = 0; c < 4; ++c) {
            /* стабилизирующая нелинейность: всё остаётся в int32 */
            uint32_t v = (uint32_t)t[r][c] ^ (k << ((r + c) & 7u));
            v = v * 2654435761u;
            m_[r][c] = (int32_t)((v >> 16) & 0x7FFFu) - 0x4000;
        }
    }
}

uint32_t FixedMatrix::checksum() const
{
    uint32_t s = 0;
    for (int r = 0; r < 4; ++r) {
        for (int c = 0; c < 4; ++c) {
            s = s * 31u + (uint32_t)m_[r][c];
        }
    }
    return s;
}

namespace {

/* ---------- Задача A: матричные итерации + LCG (наполнитель до триггера) ---------- */
void taskComputeA(void *)
{
    uint32_t acc = 0xA5A5A5A5u;
    mx.identity();
    for (uint32_t r = 0; r < 120u; ++r) {
        mx.step(lcgA.next());
        for (uint32_t i = 0; i < 64u; ++i) {
            acc = acc * 1664525u + 1013904223u;
            acc ^= r;
        }
    }
    Msg m = { TAG_A, mx.checksum() ^ acc, 0u };
    xQueueSend(qTrig, &m, portMAX_DELAY);
    vTaskSuspend(nullptr);
}

/* ---------- Задача-триггер: SCR1 issue #80 ПО СЕРЕДИНЕ программы ---------- */
void taskTrigger(void *)
{
    Msg m;
    xQueueReceive(qTrig, &m, portMAX_DELAY);
    xQueueSend(qRep, &m, portMAX_DELAY);      /* переслать A репортёру */

    uint32_t hi = 0;
    uint32_t lo = 0;
    /* Репродуктор #80: mcycleh=0; mcycle=0xFFFFFF00; 8 nop (lo < 0x100, 32-бит
     * carry невозможен); csrw mcycle,0 -> mcycleh обязан остаться 0.
     * Баг RTL (scr1_pipe_csr.sv:908): mcycleh станет 1. */
    __asm__ volatile(
        ".globl ml_trigger_start\n\t"
        "ml_trigger_start:\n\t"
        "csrw mcycleh, zero\n\t"
        "csrw mcycle, zero\n\t"
        "li t0, 0xffffff00\n\t"
        "csrw mcycle, t0\n\t"
        "nop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\t"
        "csrw mcycle, zero\n\t"
        "csrr %0, mcycleh\n\t"
        "csrr %1, mcycle\n\t"
        ".globl ml_trigger_end\n\t"
        "ml_trigger_end:\n\t"
        : "=r"(hi), "=r"(lo)
        :
        : "t0");

    Msg t = { TAG_T, hi, lo };
    xQueueSend(qRep, &t, portMAX_DELAY);
    Msg tok = { TAG_B, 0u, 0u };
    xQueueSend(qTokB, &tok, portMAX_DELAY);   /* запустить ComputeB */
    vTaskSuspend(nullptr);
}

/* ---------- Задача B: RingBuffer + LCG + матрица (наполнитель после триггера) ---------- */
void taskComputeB(void *)
{
    Msg tok;
    xQueueReceive(qTokB, &tok, portMAX_DELAY);
    uint32_t acc = 0x5A5A5A5Au;
    for (uint32_t i = 0; i < 2048u; ++i) {
        uint32_t v = lcgB.next();
        if (ring.size() == 64u) {
            uint32_t out = 0;
            ring.pop(out);
            acc += out;
            acc = (acc << 1) | (acc >> 31);
        }
        ring.push(v);
        if ((i & 31u) == 0u) {
            mx.step(v);
        }
    }
    uint32_t out = 0;
    while (ring.pop(out)) {
        acc ^= out * 2654435761u;
    }
    Msg m = { TAG_B, mx.checksum() ^ acc, 0u };
    xQueueSend(qRep, &m, portMAX_DELAY);
    vTaskSuspend(nullptr);
}

/* ---------- Репортёр: печать через SIM_PRINT и выход (sc_exit -> SIM_EXIT/STOP) ---------- */
void taskReporter(void *)
{
    Msg a, t, b;
    xQueueReceive(qRep, &a, portMAX_DELAY);   /* TAG_A */
    xQueueReceive(qRep, &t, portMAX_DELAY);   /* TAG_T */
    xQueueReceive(qRep, &b, portMAX_DELAY);   /* TAG_B */

    uint32_t rc = 0;
    con_puts("mcycle_rtos v1 (FreeRTOS cooperative; issue #80 trigger in the middle)\n");
    con_puts("chk_a   = 0x"); con_puthex(a.v0); con_putc('\n');
    con_puts("mcycle  = 0x"); con_puthex(t.v1); con_putc('\n');
    con_puts("mcycleh = 0x"); con_puthex(t.v0); con_putc('\n');
    con_puts("chk_b   = 0x"); con_puthex(b.v0); con_putc('\n');
    con_puts("checksum= 0x"); con_puthex(a.v0 ^ b.v0); con_putc('\n');
    if (t.v0 != 0u) {
        con_puts("BUG #80 reproduced: mcycleh spuriously changed\n");
        rc |= 1u;
    } else {
        con_puts("OK: mcycleh unchanged\n");
    }
    if (CHK_GOLDEN_A != 0u && a.v0 != CHK_GOLDEN_A) {
        con_puts("CHECKSUM A MISMATCH vs golden\n");
        rc |= 2u;
    }
    if (CHK_GOLDEN_B != 0u && b.v0 != CHK_GOLDEN_B) {
        con_puts("CHECKSUM B MISMATCH vs golden\n");
        rc |= 2u;
    }
    sc_exit(rc, 0u, 0u, 0u, 0u);
}

}  // namespace

void app_start(void)
{
    qTrig = xQueueCreate(2, sizeof(Msg));
    qRep  = xQueueCreate(4, sizeof(Msg));
    qTokB = xQueueCreate(2, sizeof(Msg));

    xTaskCreate(taskComputeA, "cmpA", 384, nullptr, 1, nullptr);
    xTaskCreate(taskTrigger,  "trig", 256, nullptr, 1, nullptr);
    xTaskCreate(taskComputeB, "cmpB", 384, nullptr, 1, nullptr);
    xTaskCreate(taskReporter, "rep",  320, nullptr, 1, nullptr);
}
