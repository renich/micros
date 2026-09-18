.global switchContext
switchContext:
.global switchContextSysV
switchContextSysV:
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, (%rdi)
    movq %rsi, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

.global switchContextWin64
switchContextWin64:
    pushq %rbp
    pushq %rbx
    pushq %rdi
    pushq %rsi
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $160, %rsp
    movdqu %xmm6, 0(%rsp)
    movdqu %xmm7, 16(%rsp)
    movdqu %xmm8, 32(%rsp)
    movdqu %xmm9, 48(%rsp)
    movdqu %xmm10, 64(%rsp)
    movdqu %xmm11, 80(%rsp)
    movdqu %xmm12, 96(%rsp)
    movdqu %xmm13, 112(%rsp)
    movdqu %xmm14, 128(%rsp)
    movdqu %xmm15, 144(%rsp)

    movq %rsp, (%rcx)
    movq %rdx, %rsp

    movdqu 0(%rsp), %xmm6
    movdqu 16(%rsp), %xmm7
    movdqu 32(%rsp), %xmm8
    movdqu 48(%rsp), %xmm9
    movdqu 64(%rsp), %xmm10
    movdqu 80(%rsp), %xmm11
    movdqu 96(%rsp), %xmm12
    movdqu 112(%rsp), %xmm13
    movdqu 128(%rsp), %xmm14
    movdqu 144(%rsp), %xmm15
    addq $160, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rsi
    popq %rdi
    popq %rbx
    popq %rbp
    ret
