/*
 * app.hpp — «классическая» C++-программа-стенд под FreeRTOS (кооперативный).
 *
 * Сценарий (детерминированный, сериализован очередями):
 *   ComputeA (матрица Q8 + LCG)  -> [qTrig] -> Trigger (issue #80 asm, метки
 *   ml_trigger_start/end) -> [qRep: A,T] + [qTokB] -> ComputeB (RingBuffer +
 *   LCG + матрица) -> [qRep: B] -> Reporter (печать через SIM_PRINT, sc_exit).
 *
 * Триггер #80 находится ПО СЕРЕДИНЕ исполнения; задачи ComputeA/ComputeB —
 * «естественный наполнитель» (реальный прикладной код вместо синтетических
 * asm-блоков) для отработки редуктора инструкций.
 */
#ifndef MCYCLE_RTOS_APP_HPP
#define MCYCLE_RTOS_APP_HPP

#include <stdint.h>
#include <stddef.h>

/* Golden-контрольные суммы: 0 = проверка выключена. Вшиваются вторым
 * проходом генерации из эталонного прогона Spike (см. verify_rtos.sh). */
#define CHK_GOLDEN_A 0x523ad7a9u
#define CHK_GOLDEN_B 0x48fa9986u

/* Детерминированный LCG-генератор */
class Lcg {
public:
    explicit Lcg(uint32_t seed) : s_(seed) {}
    uint32_t next()
    {
        s_ = s_ * 1103515245u + 12345u;
        return (s_ >> 9) & 0x7FFFFFu;
    }
private:
    uint32_t s_;
};

/* Кольцевой буфер (шаблон, без динамической памяти) */
template <typename T, size_t N>
class RingBuffer {
public:
    bool push(const T &v)
    {
        if (count_ == N) { return false; }
        buf_[tail_] = v;
        tail_ = (tail_ + 1u) % N;
        ++count_;
        return true;
    }
    bool pop(T &v)
    {
        if (count_ == 0u) { return false; }
        v = buf_[head_];
        head_ = (head_ + 1u) % N;
        --count_;
        return true;
    }
    size_t size() const { return count_; }
private:
    T buf_[N];
    size_t head_ = 0;
    size_t tail_ = 0;
    size_t count_ = 0;
};

/* Матрица 4x4 в Q8: детерминированные итерации без переполнения */
class FixedMatrix {
public:
    void identity();
    void step(uint32_t k);
    uint32_t checksum() const;
private:
    int32_t m_[4][4];
};

void app_start(void);

#endif /* MCYCLE_RTOS_APP_HPP */
