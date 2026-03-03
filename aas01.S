#include "hardware/regs/addressmap.h"
#include "hardware/regs/timer.h"
#include "hardware/regs/m0plus.h"
#include "hardware/regs/io_bank0.h"

.syntax unified
.cpu cortex-m0plus
.thumb

.global main_asm
.align 4

// =========================================================
// Constants
// =========================================================

.equ DFLT_STATE_STRT,    1
.equ DFLT_STATE_STOP,    0
.equ DFLT_ALARM_TIME,    1000000        @ 1 second

.equ GPIO_LED_PIN,       25
.equ GPIO_DIR_OUT,       1
.equ GPIO_DIR_IN,        0
.equ LED_VAL_OFF,        0

.equ GPIO_BTN_EN,        21
.equ GPIO_BTN_EN_MSK,    0x00400000

.equ ALRM_ISR_OFFSET,    0x40
.equ GPIO_ISR_OFFSET,    0x74

.equ GPIO_IRQ_NUM,       13
.equ GPIO_IRQ_MSK,       (1 << GPIO_IRQ_NUM)


// =========================================================
// External C wrapper functions
// =========================================================

.extern asm_gpio_init
.extern asm_gpio_set_dir
.extern asm_gpio_set_irq
.extern asm_gpio_put
.extern asm_gpio_get
.extern printf


// =========================================================
// main_asm
// =========================================================

main_asm:

    // Print startup message
    ldr  r0, =msg
    bl   printf


    // -----------------------------------------------------
    // LED Setup
    // -----------------------------------------------------

    movs r0, #GPIO_LED_PIN
    bl   asm_gpio_init

    movs r0, #GPIO_LED_PIN
    movs r1, #GPIO_DIR_OUT
    bl   asm_gpio_set_dir

    movs r0, #GPIO_LED_PIN
    movs r1, #LED_VAL_OFF
    bl   asm_gpio_put


    // -----------------------------------------------------
    // Install ALARM0 ISR
    // -----------------------------------------------------

    ldr  r0, =(PPB_BASE + M0PLUS_VTOR_OFFSET)
    ldr  r1, [r0]
    adds r1, r1, #ALRM_ISR_OFFSET
    ldr  r2, =alarm0_isr
    str  r2, [r1]

    // Enable ALARM0 inside TIMER
    ldr  r0, =(TIMER_BASE + TIMER_INTE_OFFSET)
    ldr  r1, [r0]
    movs r2, #1
    orrs r1, r1, r2
    str  r1, [r0]

    // Clear pending IRQ0
    ldr  r0, =(PPB_BASE + M0PLUS_NVIC_ICPR_OFFSET)
    movs r1, #1
    str  r1, [r0]

    // Enable IRQ0
    ldr  r0, =(PPB_BASE + M0PLUS_NVIC_ISER_OFFSET)
    movs r1, #1
    str  r1, [r0]


    // -----------------------------------------------------
    // Button GP21 Setup
    // -----------------------------------------------------

    movs r0, #GPIO_BTN_EN
    bl   asm_gpio_init

    movs r0, #GPIO_BTN_EN
    movs r1, #GPIO_DIR_IN
    bl   asm_gpio_set_dir

    // Install GPIO ISR
    ldr  r0, =(PPB_BASE + M0PLUS_VTOR_OFFSET)
    ldr  r1, [r0]
    adds r1, r1, #GPIO_ISR_OFFSET
    ldr  r2, =gpio_isr
    str  r2, [r1]

    // Clear pending IO_BANK0 interrupt
    ldr  r0, =(IO_BANK0_BASE + IO_BANK0_INTR2_OFFSET)
    ldr  r1, =GPIO_BTN_EN_MSK
    str  r1, [r0]

    // Clear NVIC pending
    ldr  r0, =(PPB_BASE + M0PLUS_NVIC_ICPR_OFFSET)
    ldr  r1, =GPIO_IRQ_MSK
    str  r1, [r0]

    // Enable NVIC GPIO interrupt
    ldr  r0, =(PPB_BASE + M0PLUS_NVIC_ISER_OFFSET)
    ldr  r1, =GPIO_IRQ_MSK
    str  r1, [r0]

    // Enable falling edge interrupt on GP21
    movs r0, #GPIO_BTN_EN
    bl   asm_gpio_set_irq


    // Schedule first alarm
    bl   schedule_next_alarm


main_loop:
    wfi
    b main_loop


// =========================================================
// schedule_next_alarm
// =========================================================

schedule_next_alarm:
    push {lr}

    ldr  r1, =(TIMER_BASE + TIMER_TIMELR_OFFSET)
    ldr  r0, [r1]

    ldr  r2, =ltimer
    ldr  r2, [r2]

    adds r0, r0, r2

    ldr  r1, =(TIMER_BASE + TIMER_ALARM0_OFFSET)
    str  r0, [r1]

    pop  {pc}


// =========================================================
// ALARM0 ISR
// =========================================================

.thumb_func
alarm0_isr:
    push {r0-r3, lr}

    // Clear alarm interrupt
    ldr  r0, =(TIMER_BASE + TIMER_INTR_OFFSET)
    movs r1, #1
    str  r1, [r0]

    // Check paused state
    ldr  r0, =lstate
    ldr  r0, [r0]
    cmp  r0, #DFLT_STATE_STOP
    beq  alarm_skip_toggle

    // Toggle LED
    movs r0, #GPIO_LED_PIN
    bl   asm_gpio_get
    movs r1, #1
    eors r0, r0, r1
    mov  r1, r0
    movs r0, #GPIO_LED_PIN
    bl   asm_gpio_put

alarm_skip_toggle:
    bl   schedule_next_alarm

    pop  {r0-r3, pc}


// =========================================================
// GPIO ISR (Pause / Resume)
// =========================================================

.thumb_func
gpio_isr:
    push {r0-r3, lr}

    // Check if GP21 triggered interrupt
    ldr  r0, =(IO_BANK0_BASE + IO_BANK0_PROC0_INTS2_OFFSET)
    ldr  r1, [r0]

    ldr  r2, =GPIO_BTN_EN_MSK
    tst  r1, r2
    beq  gpio_exit

    // Clear interrupt
    ldr  r0, =(IO_BANK0_BASE + IO_BANK0_INTR2_OFFSET)
    str  r2, [r0]

    // Toggle running state
    ldr  r0, =lstate
    ldr  r1, [r0]
    movs r2, #1
    eors r1, r2
    str  r1, [r0]

gpio_exit:
    pop  {r0-r3, pc}


// =========================================================
// Data
// =========================================================

.align 4
msg: .asciz "AAS01 - Pause/Resume Working\n"

.data
.align 4
lstate: .word DFLT_STATE_STRT
ltimer: .word DFLT_ALARM_TIME