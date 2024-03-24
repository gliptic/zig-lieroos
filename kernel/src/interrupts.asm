default rel
 
extern idtDesc
extern isrHandler

%macro pushAll 0
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
%endmacro

%macro popAll 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
%endmacro

isrCommon:
    pushAll
    
    mov    rdi, rsp
    cld
    call   isrHandler

    popAll

    add      rsp, 16
    sti
    iretq

%macro ISR_NOERRCODE 1
  global isr%1
  isr%1:
    cli
    push byte 0
    push byte %1
    jmp isrCommon
%endmacro

%macro ISR_ERRCODE 1
  global isr%1
  isr%1:
    cli
    push byte 0
    push byte %1
    jmp isrCommon
%endmacro

ISR_NOERRCODE 0
ISR_NOERRCODE 1
ISR_NOERRCODE 2
ISR_NOERRCODE 3
ISR_NOERRCODE 4
ISR_NOERRCODE 5
ISR_NOERRCODE 6
ISR_NOERRCODE 7
ISR_ERRCODE   8
ISR_NOERRCODE 9
ISR_ERRCODE   10
ISR_ERRCODE   11
ISR_ERRCODE   12
ISR_ERRCODE   13
ISR_ERRCODE   14
ISR_NOERRCODE 15
ISR_NOERRCODE 16
ISR_ERRCODE   17
ISR_NOERRCODE 18
;ISR_NOERRCODE 19
;ISR_NOERRCODE 20
;ISR_NOERRCODE 21
;ISR_NOERRCODE 22
;ISR_NOERRCODE 23
;ISR_NOERRCODE 24
;ISR_NOERRCODE 25
;ISR_NOERRCODE 26
;ISR_NOERRCODE 27
;ISR_NOERRCODE 28
;ISR_NOERRCODE 29
;ISR_NOERRCODE 30
;ISR_NOERRCODE 31

ISR_NOERRCODE 33
ISR_NOERRCODE 49

global gdtLoad
gdtLoad:
    movzx rsi, si
    movzx rdx, dx

    push rbp
    mov  rbp, rsp
    lgdt [rdi]

    push rdx
    push rbp
    pushf
    push rsi
    lea rax, trampoline
    push rax

    iretq

trampoline:
    mov rsp, rbp
    pop rbp

    mov ss, dx
    mov gs, dx
    mov fs, dx
    mov ds, dx
    mov es, dx

    retq

global enableSse
enableSse:
    mov rax, cr0
    and ax, 0xFFFB		;clear coprocessor emulation CR0.EM
    or ax, 0x2			;set coprocessor monitoring  CR0.MP
    mov cr0, rax
    mov rax, cr4
    or ax, 3 << 9		;set CR4.OSFXSR and CR4.OSXMMEXCPT at the same time
    mov cr4, rax
    ret
