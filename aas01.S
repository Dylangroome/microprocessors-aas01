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
// Constants (from assignment handout for GPIO masks) :contentReference[oaicite:1]{index=1}
// =========================================================

.equ DFLT_STATE_STRT,    1
.equ DFLT_STATE_STOP,    0
.equ DFLT_ALARM_TIME,    1000000        @ 1 second

.equ GPIO_LED_PIN,       25             @ your working LED
.equ GPIO_DIR_OUT,       1
.equ GPIO_DIR_IN,        0
.equ LED_VAL_OFF,        0

.equ GPIO_BTN_DN,        20             @ GP20 = slower
.equ GPIO_BTN_EN,        21             @ GP21 = pause/resume
.equ GPIO_BTN_UP,        22             @ GP22 = faster

.equ GPIO_BTN_DN_MSK,    0x00040000     @ Bit-18 for falling-edge on GP20 :contentReference[oaicite:2]{index=2}
.equ GPIO_BTN_EN_MSK,    0x00400000     @ Bit-22 for falling-edge on GP21 :contentReference[oaicite:3]{index=3}
.equ GPIO_BTN_UP_MSK,    0x04000000     @ Bit-26 for falling-edge on GP22 :contentReference[oaicite:4]{index=4}

.equ ALRM_ISR_OFFSET,    0x40           @ IRQ0 (ALARM0)
.equ GPIO_ISR_OFFSET,    0x74           @ IRQ13 (GPIO)

.equ GPIO_IRQ_NUM,       13
.equ GPIO_IRQ_MSK,       (1 << GPIO_IRQ_NUM)

.equ INTERVAL_MIN,       20000          @ 20ms clamp for "too fast"


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
    ldr  r0, =msg
    bl   printf

    // ---------------- LED setup ----------------
    movs r0, #GPIO_LED_PIN
    bl   asm_gpio_init
    movs r0, #GPIO_LED_PIN
    movs r1, #GPIO_DIR_OUT
    bl   asm_gpio_set_dir
    movs r0, #GPIO_LED_PIN
    movs r1, #LED_VAL_OFF
    bl   asm_gpio_put

    // ---------------- Install ALARM0 ISR ----------------
    ldr  r0, =(PPB_BASE + M0PLUS_VTOR_OFFSET)
    ldr  r1, [r0]
    adds r1, r1, #ALRM_ISR_OFFSET
    ldr  r2, =alarm0_isr
    str  r2, [r1]

    // Enable ALARM0 in TIMER (INTE bit0)
    ldr  r0, =(TIMER_BASE + TIMER_INTE_OFFSET)
    ldr  r1, [r0]
    movs r2, #1
    orrs r1, r1, r2
    str  r1, [r0]

    // Clear pending IRQ0 + enable IRQ0
    ldr  r0, =(PPB_BASE + M0PLUS_NVIC_ICPR_OFFSET)
    movs r1, #1
    str  r1, [r0]
    ldr  r0, =(PPB_BASE + M0PLUS_NVIC_ISER_OFFSET)
    movs r1, #1
    str  r1, [r0]

    // ---------------- Buttons: GP20/21/22 setup ----------------
    // Init as inputs
    movs r0, #GPIO_BTN_DN
    bl   asm_gpio_init
    movs r0, #GPIO_BTN_DN
    movs r1, #GPIO_DIR_IN
    bl   asm_gpio_set_dir

    movs r0, #GPIO_BTN_EN
    bl   asm_gpio_init
    movs r0, #GPIO_BTN_EN
    movs r1, #GPIO_DIR_IN
    bl   asm_gpio_set_dir

    movs r0, #GPIO_BTN_UP
    bl   asm_gpio_init
    movs r0, #GPIO_BTN_UP
    movs r1, #GPIO_DIR_IN
    bl   asm_gpio_set_dir

    // Install GPIO ISR (IRQ13)
    ldr  r0, =(PPB_BASE + M0PLUS_VTOR_OFFSET)
    ldr  r1, [r0]
    adds r1, r1, #GPIO_ISR_OFFSET
    ldr  r2, =gpio_isr
    str  r2, [r1]

    // Clear any pending IO_BANK0 interrupts for these buttons (INTR2)
    ldr  r0, =(IO_BANK0_BASE + IO_BANK0_INTR2_OFFSET)
    ldr  r1, =GPIO_BTN_DN_MSK
    str  r1, [r0]
    ldr  r1, =GPIO_BTN_EN_MSK
    str  r1, [r0]
    ldr  r1, =GPIO_BTN_UP_MSK
    str  r1, [r0]

    // Clear pending + enable NVIC GPIO IRQ13
    ldr  r0, =(PPB_BASE + M0PLUS_NVIC_ICPR_OFFSET)
    ldr  r1, =GPIO_IRQ_MSK
    str  r1, [r0]
    ldr  r0, =(PPB_BASE + M0PLUS_NVIC_ISER_OFFSET)
    ldr  r1, =GPIO_IRQ_MSK
    str  r1, [r0]

    // Enable falling-edge events on all 3 pins
    movs r0, #GPIO_BTN_DN
    bl   asm_gpio_set_irq
    movs r0, #GPIO_BTN_EN
    bl   asm_gpio_set_irq
    movs r0, #GPIO_BTN_UP
    bl   asm_gpio_set_irq

    // Schedule first alarm
    bl   schedule_next_alarm

main_loop:
    wfi
    b main_loop


// =========================================================
// schedule_next_alarm: ALARM0 = TIMELR + ltimer
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

    // If paused, don't toggle LED
    ldr  r0, =lstate
    ldr  r0, [r0]
    cmp  r0, #DFLT_STATE_STOP
    beq  alarm_resched

    // Toggle LED
    movs r0, #GPIO_LED_PIN
    bl   asm_gpio_get
    movs r1, #1
    eors r0, r0, r1
    mov  r1, r0
    movs r0, #GPIO_LED_PIN
    bl   asm_gpio_put

alarm_resched:
    bl   schedule_next_alarm
    pop  {r0-r3, pc}


// =========================================================
// GPIO ISR: GP21 pause/resume + GP20/GP22 speed control
// =========================================================

.thumb_func
gpio_isr:
    push {r0-r7, lr}

    // Read GPIO interrupt status (group 2 per assignment table)
    ldr  r0, =(IO_BANK0_BASE + IO_BANK0_PROC0_INTS2_OFFSET)
    ldr  r1, [r0]

    // ---------------- GP21: pause/resume ----------------
    ldr  r2, =GPIO_BTN_EN_MSK
    tst  r1, r2
    beq  check_dn

    // Clear GP21 interrupt
    ldr  r0, =(IO_BANK0_BASE + IO_BANK0_INTR2_OFFSET)
    str  r2, [r0]

    // Toggle lstate
    ldr  r3, =lstate
    ldr  r4, [r3]
    movs r5, #1
    eors r4, r5
    str  r4, [r3]

check_dn:
    // ---------------- GP20: slower (interval doubles) ----------------
    ldr  r2, =GPIO_BTN_DN_MSK
    tst  r1, r2
    beq  check_up

    // Clear GP20 interrupt
    ldr  r0, =(IO_BANK0_BASE + IO_BANK0_INTR2_OFFSET)
    str  r2, [r0]

    // If paused -> reset interval to default
    ldr  r3, =lstate
    ldr  r4, [r3]
    cmp  r4, #DFLT_STATE_STOP
    bne  dn_running

    ldr  r3, =ltimer
    ldr  r4, =DFLT_ALARM_TIME
    str  r4, [r3]
    b    check_up

dn_running:
    // running: ltimer <<= 1
    ldr  r3, =ltimer
    ldr  r4, [r3]
    lsls r4, r4, #1
    str  r4, [r3]

check_up:
    // ---------------- GP22: faster (interval halves) ----------------
    ldr  r2, =GPIO_BTN_UP_MSK
    tst  r1, r2
    beq  gpio_done

    // Clear GP22 interrupt
    ldr  r0, =(IO_BANK0_BASE + IO_BANK0_INTR2_OFFSET)
    str  r2, [r0]

    // If paused -> reset interval to default
    ldr  r3, =lstate
    ldr  r4, [r3]
    cmp  r4, #DFLT_STATE_STOP
    bne  up_running

    ldr  r3, =ltimer
    ldr  r4, =DFLT_ALARM_TIME
    str  r4, [r3]
    b    gpio_done

up_running:
    // running: ltimer >>= 1 (clamp)
    ldr  r3, =ltimer
    ldr  r4, [r3]
    lsrs r4, r4, #1

    ldr  r6, =INTERVAL_MIN
    cmp  r4, r6
    bhs  up_store
    mov  r4, r6

up_store:
    str  r4, [r3]

gpio_done:
    pop  {r0-r7, pc}


// =========================================================
// Data
// =========================================================

.align 4
msg: .asciz "AAS01 - Pause + Speed (GP20/GP22)\n"

.data
.align 4
lstate: .word DFLT_STATE_STRT
ltimer: .word DFLT_ALARM_TIME