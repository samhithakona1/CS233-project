# =================== syscall constants ====================
PRINT_STRING            = 4
PRINT_CHAR              = 11
PRINT_INT               = 1

# =================== MMIO addresses ======================
ANGLE                   = 0xffff0014
ANGLE_CONTROL           = 0xffff0018
VELOCITY                = 0xffff0010

BOT_X                   = 0xffff0020
BOT_Y                   = 0xffff0024

NUM_BUNNIES_CARRIED     = 0xffff0050
SEARCH_BUNNIES          = 0xffff0054
CATCH_BUNNY             = 0xffff0058
PUT_BUNNIES_IN_PLAYPEN  = 0xffff005c
PLAYPEN_LOCATION        = 0xffff0044

TIMER                   = 0xffff001c
BONK_INT_MASK           = 0x1000
BONK_ACK                = 0xffff0060
TIMER_INT_MASK          = 0x8000
TIMER_ACK               = 0xffff006c

# =================== data section ========================
.data
.align 2

bunnies_info: 
    num_bunnies:   .word 0
    bunnies:       .space 480      # 30 bunnies * 16 bytes

# State variables
has_bonked:          .byte 0
current_angle:       .word 0
target_weight:       .word 100
current_weight:      .word 0
playpen_location:    .word 0
carrots_count:       .word 100
current_target_bunny:.word -1
state:               .word 0       # 0=search,1=move,2=catch,3=move_playpen,4=deliver
search_pattern:      .word 0       # 0=right,1=down,2=left,3=up

# =================== text section ========================
.text
.globl main
main:
    # Enable interrupts
    li $t0, 1
    or $t0, $t0, TIMER_INT_MASK
    or $t0, $t0, BONK_INT_MASK
    or $t0, $t0, 1          # global enable
    mtc0 $t0, $12

    # Initialize movement
    li $t0, 0
    sw $t0, current_angle
    sw $t0, ANGLE
    li $t0, 1
    sw $t0, ANGLE_CONTROL
    li $t0, 10
    sw $t0, VELOCITY

    # Initialize state
    li $t0, -1
    sw $t0, current_target_bunny
    li $t0, 0
    sw $t0, state
    li $t0, 0
    sw $t0, search_pattern

    # Initialize carrots
    li $t0, 100
    sw $t0, carrots_count

    # Get playpen location
    lw $t0, PLAYPEN_LOCATION
    sw $t0, playpen_location

main_loop:
    # Handle bonk
    lb $t0, has_bonked
    beqz $t0, check_state
    jal handle_bonk
    sb $zero, has_bonked

check_state:
    lw $t0, state
    beq $t0, 0, state_search
    beq $t0, 1, state_move_to_bunny
    beq $t0, 2, state_catch
    beq $t0, 3, state_move_to_playpen
    beq $t0, 4, state_deliver
    j main_loop

# ================== States ==============================
state_search:
    jal search_for_bunnies
    j main_loop

state_move_to_bunny:
    jal move_to_target_bunny
    j main_loop

state_catch:
    jal catch_target_bunny
    j main_loop

state_move_to_playpen:
    jal move_to_playpen
    j main_loop

state_deliver:
    jal deliver_bunnies
    j main_loop

# ================== Bonk Handler ========================
handle_bonk:
    addi $sp, $sp, -8
    sw $ra, 0($sp)
    sw $t0, 4($sp)

    # Stop movement
    li $t0, 0
    sw $t0, VELOCITY

    # Turn 90 deg
    lw $t0, current_angle
    addi $t0, $t0, 90
    blt $t0, 360, bonk_ok
    addi $t0, $t0, -360
bonk_ok:
    sw $t0, current_angle
    sw $t0, ANGLE
    li $t0, 1
    sw $t0, ANGLE_CONTROL

    # Delay
    li $t0, 50000
bonk_delay:
    addi $t0, $t0, -1
    bnez $t0, bonk_delay

    # Resume velocity
    li $t0, 10
    sw $t0, VELOCITY

    lw $ra, 0($sp)
    lw $t0, 4($sp)
    addi $sp, $sp, 8
    jr $ra

# ================== Bunny Search ========================
search_for_bunnies:
    addi $sp, $sp, -4
    sw $ra, 0($sp)

    jal check_nearby_bunnies
    lw $t0, state
    bne $t0, 0, search_done

    jal find_next_bunny

search_done:
    lw $ra, 0($sp)
    addi $sp, $sp, 4
    jr $ra

check_nearby_bunnies:
    addi $sp, $sp, -16
    sw $ra, 0($sp)
    sw $s0, 4($sp)
    sw $s1, 8($sp)
    sw $s2, 12($sp)
    sw $s3, 16($sp)

    lw $s0, BOT_X
    lw $s1, BOT_Y
    la $s2, bunnies_info
    lw $s3, 0($s2)             # num_bunnies
    beqz $s3, nearby_done

    li $t0, 0
nearby_loop:
    la $t1, bunnies_info
    addi $t1, $t1, 4           # skip num_bunnies word
    sll $t2, $t0, 4            # multiply by 16 bytes
    add $t1, $t1, $t2

    lw $t3, 12($t1)            # caught flag
    bnez $t3, next_nearby

    lw $t4, 0($t1)             # bunny x
    lw $t5, 4($t1)             # bunny y

    sub $t6, $s0, $t4
    bltz $t6
    negu $t6, $t6
    sub $t7, $s1, $t5
    bltz $t7
    negu $t7, $t7
    add $t8, $t6, $t7
    ble $t8, 15, found_nearby
    j next_nearby

found_nearby:
    sw $t0, current_target_bunny
    sw $zero, VELOCITY
    li $t0, 2
    sw $t0, state
    j nearby_done

next_nearby:
    addi $t0, $t0, 1
    blt $t0, $s3, nearby_loop

nearby_done:
    lw $ra, 0($sp)
    lw $s0, 4($sp)
    lw $s1, 8($sp)
    lw $s2, 12($sp)
    lw $s3, 16($sp)
    addi $sp, $sp, 16
    jr $ra

find_next_bunny:
    addi $sp, $sp,
