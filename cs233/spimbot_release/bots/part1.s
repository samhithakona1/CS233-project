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

# Local bookkeeping for which scanned bunny indices we've already caught
caught_flags:       .space 120      # 30 words

# State variables
has_bonked:          .byte 0
current_angle:       .word 0
target_weight:       .word 100
current_weight:      .word 0       # total weight currently carried
delivered_weight:    .word 0       # total weight delivered to playpen
playpen_location:    .word 0
carrots_count:       .word 100
current_target_bunny:.word -1
state:               .word 0       # 0=search,1=move,2=catch,3=move_playpen,4=deliver
search_pattern:      .word 0       # 0=right,1=down,2=left,3=up

# =================== text section ========================
.text
.globl main
main:
    # Disable interrupts for Part 1 (no handler needed)
    move $t0, $zero
    mtc0 $t0, $12

    # Initialize movement
    li $t0, 0
    sw $t0, current_angle
    sw $t0, ANGLE
    li $t0, 1
    sw $t0, ANGLE_CONTROL
    li $t0, 0
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

    # Zero caught_flags[0..29]
    la $t0, caught_flags
    li $t1, 30
zero_cf_loop:
    sw $zero, 0($t0)
    addi $t0, $t0, 4
    addi $t1, $t1, -1
    bgtz $t1, zero_cf_loop

    # Get playpen location
    lw $t0, PLAYPEN_LOCATION
    sw $t0, playpen_location

main_loop:
    # If we've delivered at least 100 zentners, stop
    lw $t0, delivered_weight
    li $t1, 100
    blt $t0, $t1, check_bonk
    sw $zero, VELOCITY
idle:
    j idle

check_bonk:
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
    addi $sp, $sp, -8
    sw $ra, 0($sp)
    sw $s0, 4($sp)

    # Request/update bunny scan results into our struct
    la $s0, bunnies_info
    sw $s0, SEARCH_BUNNIES

    # If already carrying 100 zentners, go deliver
    lw $t0, current_weight
    li $t1, 100
    bge $t0, $t1, go_deliver_from_search

    # Prefer catching a bunny if one is within 5 pixels and fits
    jal check_nearby_bunnies
    lw $t0, state
    bne $t0, 0, search_done

    # Otherwise pick the next target to chase
    jal find_next_bunny
    j search_done

go_deliver_from_search:
    li $t0, 3                  # state_move_to_playpen
    sw $t0, state

search_done:
    lw $ra, 0($sp)
    lw $s0, 4($sp)
    addi $sp, $sp, 8
    jr $ra

check_nearby_bunnies:
    addi $sp, $sp, -24
    sw $ra, 0($sp)
    sw $s0, 4($sp)
    sw $s1, 8($sp)
    sw $s2, 12($sp)
    sw $s3, 16($sp)
    sw $s4, 20($sp)

    lw $s0, BOT_X
    lw $s1, BOT_Y
    la $s2, bunnies_info
    lw $s3, 0($s2)             # num_bunnies
    beqz $s3, nearby_done

    lw $t9, current_weight     # remaining capacity check
    li $s4, 100
    sub $s4, $s4, $t9          # remaining capacity = 100 - current_weight
    blez $s4, nearby_done

    li $t0, 0
nearby_loop:
    la $t1, bunnies_info
    addi $t1, $t1, 4           # skip num_bunnies word
    sll $t2, $t0, 4            # multiply by 16 bytes
    add $t1, $t1, $t2

    # skip if already caught (from our local flags)
    la $t9, caught_flags
    sll $t6, $t0, 2
    add $t9, $t9, $t6
    lw $t3, 0($t9)
    bnez $t3, next_nearby

    lw $t4, 8($t1)             # bunny weight
    bgt $t4, $s4, next_nearby  # skip if won't fit

    lw $t4, 0($t1)             # bunny x
    lw $t5, 4($t1)             # bunny y

    sub $t6, $s0, $t4
    bltz $t6, absx_ok
    j absy
absx_ok:
    negu $t6, $t6
absy:
    sub $t7, $s1, $t5
    bltz $t7, abssum
    j abssum2
abssum:
    negu $t7, $t7
abssum2:
    add $t8, $t6, $t7
    ble $t8, 5, found_nearby
    j next_nearby

found_nearby:
    sw $t0, current_target_bunny
    sw $zero, VELOCITY
    li $t0, 2                  # state_catch
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
    lw $s4, 20($sp)
    addi $sp, $sp, 24
    jr $ra

find_next_bunny:
    # Choose nearest not-yet-caught bunny that fits carry capacity
    addi $sp, $sp, -44
    sw $ra, 0($sp)
    sw $s0, 4($sp)
    sw $s1, 8($sp)
    sw $s2, 12($sp)
    sw $s3, 16($sp)
    sw $s4, 20($sp)
    sw $s5, 24($sp)
    sw $s6, 28($sp)
    sw $s7, 32($sp)
    sw $t0, 36($sp)
    sw $t1, 40($sp)

    la $s0, bunnies_info
    lw $s1, 0($s0)             # num_bunnies
    beqz $s1, fnb_none

    lw $s2, current_weight
    li $t0, 100
    sub $s3, $t0, $s2          # remaining capacity
    blez $s3, fnb_go_deliver

    lw $s4, BOT_X
    lw $s5, BOT_Y

    li $s6, -1                 # best_idx
    li $s7, 0x7fffffff         # best_dist

    li $t0, 0                  # i = 0
fnb_loop:
    # base address of bunny i
    addi $t1, $s0, 4
    sll $t2, $t0, 4
    add $t1, $t1, $t2

    # Skip if already caught (check our flags)
    la $t9, caught_flags
    sll $t8, $t0, 2
    add $t9, $t9, $t8
    lw $t3, 0($t9)
    bnez $t3, fnb_next

    lw $t3, 8($t1)             # weight
    bgt $t3, $s3, fnb_next     # skip if too heavy

    lw $t4, 0($t1)             # x
    lw $t5, 4($t1)             # y
    sub $t6, $s4, $t4
    bltz $t6, fnb_absx
    j fnb_absy
fnb_absx:
    negu $t6, $t6
fnb_absy:
    sub $t7, $s5, $t5
    bltz $t7, fnb_abs_sum
    j fnb_abs_sum2
fnb_abs_sum:
    negu $t7, $t7
fnb_abs_sum2:
    add $t8, $t6, $t7          # manhattan distance
    bge $t8, $s7, fnb_next
    move $s7, $t8
    move $s6, $t0

fnb_next:
    addi $t0, $t0, 1
    blt $t0, $s1, fnb_loop

    bltz $s6, fnb_none         # none found

    # found best idx -> set state to move
    sw $s6, current_target_bunny
    li $t0, 1                  # state_move_to_bunny
    sw $t0, state
    j fnb_done

fnb_go_deliver:
    li $t0, 3                  # state_move_to_playpen
    sw $t0, state
    j fnb_done

fnb_none:
    # If carrying anything, go deliver; else remain searching
    lw $t0, current_weight
    blez $t0, fnb_done
    li $t1, 3
    sw $t1, state

fnb_done:
    lw $ra, 0($sp)
    lw $s0, 4($sp)
    lw $s1, 8($sp)
    lw $s2, 12($sp)
    lw $s3, 16($sp)
    lw $s4, 20($sp)
    lw $s5, 24($sp)
    lw $s6, 28($sp)
    lw $s7, 32($sp)
    lw $t0, 36($sp)
    lw $t1, 40($sp)
    addi $sp, $sp, 44
    jr $ra

############################################################
# Move towards current target bunny: horizontal then vertical
move_to_target_bunny:
    addi $sp, $sp, -32
    sw $ra, 0($sp)
    sw $s0, 4($sp)
    sw $s1, 8($sp)
    sw $s2, 12($sp)
    sw $s3, 16($sp)
    sw $s4, 20($sp)
    sw $s5, 24($sp)
    sw $s6, 28($sp)

    lw $s0, current_target_bunny
    bltz $s0, mtb_done

    addi $s1, $zero, 4         # reach tolerance per axis

    # Load target x,y
    la $t0, bunnies_info
    addi $t0, $t0, 4
    sll $t1, $s0, 4
    add $t0, $t0, $t1
    lw $s2, 0($t0)             # target x
    lw $s3, 4($t0)             # target y

    lw $s4, BOT_X
    lw $s5, BOT_Y

    # Move horizontally first
    sub $t2, $s2, $s4
    bltz $t2, mtb_absdx
    j mtb_checkdx
mtb_absdx:
    negu $t2, $t2
mtb_checkdx:
    ble $t2, $s1, mtb_h_done

    # Need to move in +x or -x
    lw $t3, BOT_X
    sub $t4, $s2, $t3
    bgtz $t4, mtb_go_posx
    j mtb_go_negx
mtb_go_posx:
    li $t5, 0                  # angle 0 -> +x
    sw $t5, ANGLE
    li $t6, 1
    sw $t6, ANGLE_CONTROL
    li $t7, 10
    sw $t7, VELOCITY
    j mtb_ret
mtb_go_negx:
    li $t5, 180                # angle 180 -> -x
    sw $t5, ANGLE
    li $t6, 1
    sw $t6, ANGLE_CONTROL
    li $t7, 10
    sw $t7, VELOCITY
    j mtb_ret

mtb_h_done:
    # Stop horizontal motion
    sw $zero, VELOCITY

    # Now move vertically
    sub $t2, $s3, $s5
    bltz $t2, mtb_absdy
    j mtb_checkdy
mtb_absdy:
    negu $t2, $t2
mtb_checkdy:
    ble $t2, $s1, mtb_arrived

    # Need to move in +y or -y
    lw $t3, BOT_Y
    sub $t4, $s3, $t3
    bgtz $t4, mtb_go_posy
    j mtb_go_negy
mtb_go_posy:
    li $t5, 90                 # angle 90 -> +y
    sw $t5, ANGLE
    li $t6, 1
    sw $t6, ANGLE_CONTROL
    li $t7, 10
    sw $t7, VELOCITY
    j mtb_ret
mtb_go_negy:
    li $t5, 270                # angle 270 -> -y
    sw $t5, ANGLE
    li $t6, 1
    sw $t6, ANGLE_CONTROL
    li $t7, 10
    sw $t7, VELOCITY
    j mtb_ret

mtb_arrived:
    # at target -> stop and transition to catch
    sw $zero, VELOCITY
    li $t0, 2
    sw $t0, state
    j mtb_ret

mtb_ret:
mtb_done:
    lw $ra, 0($sp)
    lw $s0, 4($sp)
    lw $s1, 8($sp)
    lw $s2, 12($sp)
    lw $s3, 16($sp)
    lw $s4, 20($sp)
    lw $s5, 24($sp)
    lw $s6, 28($sp)
    addi $sp, $sp, 32
    jr $ra

############################################################
# Attempt to catch the current target bunny
catch_target_bunny:
    addi $sp, $sp, -28
    sw $ra, 0($sp)
    sw $s0, 4($sp)
    sw $s1, 8($sp)
    sw $s2, 12($sp)
    sw $s3, 16($sp)
    sw $s4, 20($sp)
    sw $s5, 24($sp)

    lw $s0, current_target_bunny
    bltz $s0, ctb_done

    # compute target base
    la $t0, bunnies_info
    addi $t0, $t0, 4
    sll $t1, $s0, 4
    add $t0, $t0, $t1

    # Ensure we are close (<=5) to avoid wasting carrots
    lw $t2, 0($t0)             # bx
    lw $t3, 4($t0)             # by
    lw $t4, BOT_X
    lw $t5, BOT_Y
    sub $t6, $t4, $t2
    bltz $t6, ctb_absx
    j ctb_absy
ctb_absx:
    negu $t6, $t6
ctb_absy:
    sub $t7, $t5, $t3
    bltz $t7, ctb_abs_sum
    j ctb_abs_sum2
ctb_abs_sum:
    negu $t7, $t7
ctb_abs_sum2:
    add $t8, $t6, $t7
    bgt $t8, 5, ctb_to_move     # too far -> go back to move

    # Attempt catch
    li $t9, 1
    sw $t9, CATCH_BUNNY

    # Spend one carrot
    lw $s1, carrots_count
    addi $s1, $s1, -1
    sw $s1, carrots_count

    # Mark as caught in our local flags and update carried weight
    lw $s2, 8($t0)             # bunny weight
    la $t0, caught_flags
    lw $t1, current_target_bunny
    sll $t1, $t1, 2
    add $t0, $t0, $t1
    sw $t9, 0($t0)             # caught_flags[idx] = 1
    lw $s3, current_weight
    add $s3, $s3, $s2
    sw $s3, current_weight

    # Clear target and choose next step
    li $s4, -1
    sw $s4, current_target_bunny

    # If at/over capacity, go deliver; else search for next
    li $t0, 100
    bge $s3, $t0, ctb_go_deliver
    li $t1, 0                   # state_search
    sw $t1, state
    j ctb_done

ctb_go_deliver:
    li $t1, 3                   # state_move_to_playpen
    sw $t1, state
    j ctb_done

ctb_to_move:
    li $t1, 1                   # state_move_to_bunny
    sw $t1, state

ctb_done:
    lw $ra, 0($sp)
    lw $s0, 4($sp)
    lw $s1, 8($sp)
    lw $s2, 12($sp)
    lw $s3, 16($sp)
    lw $s4, 20($sp)
    lw $s5, 24($sp)
    addi $sp, $sp, 28
    jr $ra

############################################################
# Move to the playpen location
move_to_playpen:
    addi $sp, $sp, -28
    sw $ra, 0($sp)
    sw $s0, 4($sp)
    sw $s1, 8($sp)
    sw $s2, 12($sp)
    sw $s3, 16($sp)
    sw $s4, 20($sp)
    sw $s5, 24($sp)

    lw $t0, playpen_location
    andi $s0, $t0, 0xFFFF       # y (lower 16)
    srl $s1, $t0, 16            # x (upper 16)

    lw $s2, BOT_X
    lw $s3, BOT_Y

    # If not horizontally aligned, move in x first
    sub $t1, $s1, $s2
    bltz $t1, mp_absdx
    j mp_checkdx
mp_absdx:
    negu $t1, $t1
mp_checkdx:
    ble $t1, 4, mp_h_done

    # move along x toward playpen
    lw $t2, BOT_X
    sub $t3, $s1, $t2
    bgtz $t3, mp_go_posx
    j mp_go_negx
mp_go_posx:
    li $t4, 0
    sw $t4, ANGLE
    li $t5, 1
    sw $t5, ANGLE_CONTROL
    li $t6, 10
    sw $t6, VELOCITY
    j mp_ret
mp_go_negx:
    li $t4, 180
    sw $t4, ANGLE
    li $t5, 1
    sw $t5, ANGLE_CONTROL
    li $t6, 10
    sw $t6, VELOCITY
    j mp_ret

mp_h_done:
    # Stop horizontal motion
    sw $zero, VELOCITY

    # Move in y
    sub $t1, $s0, $s3
    bltz $t1, mp_absdy
    j mp_checkdy
mp_absdy:
    negu $t1, $t1
mp_checkdy:
    ble $t1, 4, mp_arrived

    lw $t2, BOT_Y
    sub $t3, $s0, $t2
    bgtz $t3, mp_go_posy
    j mp_go_negy
mp_go_posy:
    li $t4, 90
    sw $t4, ANGLE
    li $t5, 1
    sw $t5, ANGLE_CONTROL
    li $t6, 10
    sw $t6, VELOCITY
    j mp_ret
mp_go_negy:
    li $t4, 270
    sw $t4, ANGLE
    li $t5, 1
    sw $t5, ANGLE_CONTROL
    li $t6, 10
    sw $t6, VELOCITY
    j mp_ret

mp_arrived:
    sw $zero, VELOCITY
    li $t0, 4                   # state_deliver
    sw $t0, state

mp_ret:
    lw $ra, 0($sp)
    lw $s0, 4($sp)
    lw $s1, 8($sp)
    lw $s2, 12($sp)
    lw $s3, 16($sp)
    lw $s4, 20($sp)
    lw $s5, 24($sp)
    addi $sp, $sp, 28
    jr $ra

############################################################
# Deposit carried bunnies into the playpen
deliver_bunnies:
    addi $sp, $sp, -20
    sw $ra, 0($sp)
    sw $s0, 4($sp)
    sw $s1, 8($sp)
    sw $s2, 12($sp)
    sw $s3, 16($sp)

    # Verify we are within 5px of playpen center
    lw $t0, playpen_location
    andi $s0, $t0, 0xFFFF       # y
    srl $s1, $t0, 16            # x
    lw $s2, BOT_X
    lw $s3, BOT_Y

    sub $t1, $s1, $s2
    bltz $t1, d_absx
    j d_absy
d_absx:
    negu $t1, $t1
d_absy:
    sub $t2, $s0, $s3
    bltz $t2, d_abs_sum
    j d_abs_sum2
d_abs_sum:
    negu $t2, $t2
d_abs_sum2:
    add $t3, $t1, $t2
    bgt $t3, 5, d_need_move     # too far -> go back to move_to_playpen

    # Read number of bunnies currently carried and deposit all
    lw $t4, NUM_BUNNIES_CARRIED
    blez $t4, d_done_deposit
    sw $t4, PUT_BUNNIES_IN_PLAYPEN

    # Update delivered weight and reset carried weight
    lw $t5, delivered_weight
    lw $t6, current_weight
    add $t5, $t5, $t6
    sw $t5, delivered_weight
    sw $zero, current_weight

d_done_deposit:
    # Resume searching
    li $t7, 0
    sw $t7, state
    j d_ret

d_need_move:
    li $t7, 3                   # state_move_to_playpen
    sw $t7, state

d_ret:
    lw $ra, 0($sp)
    lw $s0, 4($sp)
    lw $s1, 8($sp)
    lw $s2, 12($sp)
    lw $s3, 16($sp)
    addi $sp, $sp, 20
    jr $ra
