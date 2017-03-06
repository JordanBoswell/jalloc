min_capacity = 21                     #minimum capacity for a block/chunk
min_chunk_size = min_capacity + 3     #minimum size for a chunk(capacity+head)
small_max  = 0b1111111101             #capacity max for small size-class
medium_max = 0b111111111111111111101  #capacity max for medium size-class
ptr_array_small_max_index = 125
ptr_array_medium_start_index = 126
ptr_array_max_index = 136
system_allocate_multiplier = 10       #num chunks to system-allocate when no
                                      #free block satisfies user's alloc request
wilderness_trim_threshold = 1 << 21


.bss

.global wilderness_ptr
wilderness_ptr: .skip 8  #last (top-most address/break boundary) chunk
dummy_header: .skip 3
.global dummy
.global ptr_array
dummy: .skip 40  #dummy node for null pointers of list and tree nodes
ptr_array: .skip (ptr_array_max_index+1)*8
page_size: .skip 8


.text

.macro GET_BREAK
/* Retrieve the current program break.
   %rax:         (output)  The existing program break address.
   %rdi:         (auxiliary)
*/
	mov   $12, %rax
	mov   $0, %rdi
	syscall
.endm


.macro SET_BREAK  new_break
/* Set new break
   new_break:    (input)(8-byte register)  The location to set break to.
   %rax:         (output)  The new program break address.
   %rdi:         (auxiliary)
   errors-> returns 1 if the brk call didn't update the break
*/
	mov   \new_break, %rdi
	mov   $12, %rax
	syscall
	cmp   \new_break, %rax
	jz    0f
	mov   $1, %rax
	ret
0:
.endm


.macro EXTRACT_BLOCK_INFO  modifier, ptr, offset, capacity, bits
/* Extracts the block's header/footer values.
   modifier:     (input)(immediate value)  0, 1, or 2.  The macro's behavior
                    depends on the value.  0 only extracts the capacity, 1 the
                    bits, and 2 extracts both.
   ptr:          (input)(unmodified)(8-byte register)  A pointer to be used with 
                    offset such that ptr+offset points to the first byte of the 
                    header or the first byte of the footer.
   offset:       (input)(unmodified)(8-byte register)  A integer to be used with 
                    offset such that ptr+offset points to the first byte of the 
                    header or the first byte of the footer.
   capacity:     (output)(4-byte register)  Register which, if modifier is 0 or
                    2, gets modified to contain the block's capacity.
   bits:         (output)(4-byte register)  Register which, if modifier is 1 or
                    2, gets modified to contain the block's bits.
*/
.if \modifier == 0
	mov   \offset(\ptr), \capacity
	and   $0xFFFFFF, \capacity
	shr   $3, \capacity
.elseif modifier == 1
	mov   \offset(\ptr), \bits
	and   $0x7, \bits
.elseif \modifier == 2
	mov   \offset(\ptr), \capacity
	and   $0xFFFFFF, \capacity
	mov   \capacity, \bits
	and   $0x7, \bits
	shr   $3, \capacity
.endif
.endm


.macro RB_SEARCH  key, node_ptr, parent_ptr, node_side, reg1
/* Searches the tree for key;node_ptr returns the found node(dummy if not found)
   key:          (input)(unmodified)(4-byte register)  The key(capacity) that is
                    to be searched for.
   node_ptr:     (input/output)(modified)(8-byte register)  As input: the ptr to
                    the block whose subtree(including itself) is to be searched
                    for key.  As output: ptr to the found block, or if not
                    found, a ptr to dummy.
   parent_ptr:   (output)(8-byte register)  Contains ptr to parent of node_ptr.
   node_side:    (output)(8-byte register)  0 if node is left child of parent. 1
                    if it is right child.    If the original node_ptr satisfies
                    the search, node_side remains unchanged by the macro.
   reg1:         (auxiliary)(4-byte register)
*/
	mov   $dummy, \parent_ptr
10:
	cmp   $dummy, \node_ptr
	je    10f
	EXTRACT_BLOCK_INFO 0, \node_ptr, -3, \reg1, \reg1
	cmp   \reg1, \key
	je    10f
	mov   \node_ptr, \parent_ptr
	jl    11f
	mov   16(\node_ptr), \node_ptr
	mov   $1, \node_side
	jmp   10b
11:
	mov   8(\node_ptr), \node_ptr
	xor   \node_side, \node_side
	jmp   10b
10:
.endm


.macro ADD_CAPACITY_TO_HEADER  capacity, ptr, offset
/* Writes the given capacity to the specified block's header; zeroes-out bits
   capacity      (input)(unmodified)(4-byte register)
   ptr           (input)(unmodified)(8-byte register)  A pointer to be used with 
                    offset such that ptr+offset points to the first byte of the 
                    header
   offset        (immediate)  An integer to be used with ptr such that 
                    ptr+offset points to the first byte of the header.
*/
	cmp   $medium_max, \capacity
	jg    0f
	shl   $3, \capacity
	mov   \capacity, \offset(\ptr)
	shr   $3, \capacity
	jmp   9f
0:  #large
	add   $\offset, \ptr
	mov   \capacity, -4(\ptr)
	sub   $\offset, \ptr
9:
.endm


.macro ADD_CAPACITY_TO_HEADER_KEEP_BITS  capacity, ptr, offset
/* Writes the given capacity to the specified block's header; preserves bits
   capacity      (input)(unmodified)(4-byte register)
   ptr           (input)(unmodified)(8-byte register)  A pointer to be used with 
                    offset such that ptr+offset points to the first byte of the 
                    header
   offset        (immediate)  An integer to be used with ptr such that
                    ptr+offset points to the first byte of the header.
*/
	shl   $3, \capacity
	andl  $0x7, \offset(\ptr)
	or    \capacity, \offset(\ptr)
	shr   $3, \capacity
.endm


.macro ADD_CAPACITY_TO_FOOTER  capacity, ptr, offset
/* Writes the given capacity to the specified block's footer; zeroes-out bits
   capacity:     (input)(unmodified)(4-byte register)
   ptr:          (input)(unmodified)(8-byte register)  A pointer to be used with
                    offset such that ptr+offset points to the byte preceding the
                    first byte of the footer.
   offset:       (input)(unmodified)(8-byte register)  An integer to be used with
                    ptr such that ptr+offset points to the byte preceding the
                    first byte of the footer.
*/
	shl   $11, \capacity
	mov   \capacity,\offset(\ptr)
	shr   $11, \capacity
.endm


.macro ADD_CAPACITY_TO_FOOTER_KEEP_BITS  capacity, ptr, offset
/* Writes the given capacity to the specified block's footer; preserves bits
   capacity:     (input)(unmodified)(4-byte register)
   ptr:          (input)(unmodified)(8-byte register)  A pointer to be used with
                    offset such that ptr+offset points to the byte preceding the
                    first byte of the footer.
   offset:       (input)(unmodified)(8-byte register)  An integer to be used
                    with ptr such that ptr+offset points to the byte preceding
                    the first byte of the footer.
*/
	shl   $11, \capacity
	andl  $0x700, \offset(\ptr)
	or    \capacity, \offset(\ptr)
	shr   $11, \capacity
.endm


.macro CALCULATE_SMALL_INDEX  capacity
/* Converts a capacity of a small block to its corresponding array index.
   capacity:     (input/output)(4-byte register)  The block's capacity.  This
                    gets modified to become the starting index.  
*/
	shr   $3, \capacity
	sub   $2, \capacity
.endm


.macro CALCULATE_MEDIUM_INDEX  capacity
/* Converts a capacity of a medium block to its corresponding array index.
   capacity:     (input/output)(4-byte register)  The block's capacity.  This
                    gets modified to become the starting index.  
*/
	add   $2, \capacity
	bsr   \capacity, \capacity
	add   $116, \capacity
.endm


.macro SET_COLOR  ptr, offset, color
/* Sets the color of the rb-tree node
   ptr:          (input)(unmodified)(8-byte register)  Pointer such that 
                    ptr+offset points to the first byte of the block's header.
   offset:       (immediate)  Number such that ptr+offset points to the first
                    byte of the block's header.
   color:        (input)(unmodified)(register)  The color that should be 
                    set in the block's header.  0 for black; otherwise red.
*/
	test  \color, \color
	jnz   10f
	andb  $0xFB, \offset(\ptr)
	jmp   11f
10:
	orb   $0x4, \offset(\ptr)
11:
.endm


.macro LEFT_ROTATE swap, x, y, root, index, reg1
/* Performs a left rotation with y and its right child, x.
   swap:         (immediate)  Zero for no swap at end.  Nonzero if x and y
                    should be swapped at end so that x remains as parent.
   x:            (input/output)(modified)(8-byte register)  Ptr to the parent
                    node, which, when rotated, becomes the child node.
   y:            (input/output)(modified)(8-byte register)  Ptr to the right
                    child node of x, which, when rotated, becomes the parent
                    node.
   root:         (input/output)(modified)(8-byte register)  Ptr to the root
                    node, which may get updated during rotation.
   index:        (input)(unmodified)(register)  ptr_array index which may be
                    used to update the ptr to the tree's root.
   reg1:         (auxiliary)(8-byte register)
*/
	mov   8(\y), \reg1
	mov   \reg1, 16(\x)
	mov   \x, (\reg1)
	mov   (\x), \reg1
	mov   \reg1, (\y)
	cmp   $dummy, \reg1
	jnz   20f
	mov   \y, \root
	mov   \y, ptr_array(, \index, 8)
	jmp   21f
20:
	cmp   \x, 8(\reg1)
	jnz   20f
	mov   \y, 8(\reg1)
	jmp   21f
20:
	mov   \y, 16(\reg1)
21:
	mov   \x, 8(\y)
	mov   \y, (\x)
.if \swap
	mov   \x, \reg1
	mov   \y, \x
	mov   \reg1, \y
.endif
.endm


.macro RIGHT_ROTATE swap, x, y, root, index, reg1
/* Performs a left rotation with y and its right child, x.
   swap:         (immediate)  Zero for no swap at end.  Nonzero if x and y
                    should be swapped at end so that x remains as parent.
   x:            (input/output)(modified)(8-byte register)  Ptr to the parent
                    node, which, when rotated, becomes the child node.
   y:            (input/output)(modified)(8-byte register)  Ptr to the left
                    child node of x, which, when rotated, becomes the parent
                    node.
   root:         (input/output)(modified)(8-byte register)  Ptr to the root
                    node, which may get updated during rotation.
   index:        (input)(unmodified)(register)   ptr_array index which may be
                    used to update the ptr to the tree's root.
   reg1:         (auxiliary)(8-byte register)
*/
	mov   16(\y), \reg1
	mov   \reg1, 8(\x)
	mov   \x, (\reg1)
	mov   (\x), \reg1
	mov   \reg1, (\y)
	cmp   $dummy, \reg1
	jnz   20f
	mov   \y, \root
	mov   \y, ptr_array(, \index, 8)
	jmp   21f
20:
	cmp   \x, 8(\reg1)
	jnz   20f
	mov   \y, 8(\reg1)
	jmp   21f
20:
	mov   \y, 16(\reg1)
21:
	mov   \x, 16(\y)
	mov   \y, (\x)
.if \swap
	mov   \x, \reg1
	mov   \y, \x
	mov   \reg1, \y
.endif
.endm


.macro RB_TRANSPLANT  u, v, index, reg1
/* clrs' RB-Translplant; connects v to u's parent
   u:            (input)(unmodified)(8-byte register)  A pointer to the u block.
   v:            (input)(unmodified)(8-byte register)  A pointer to the v block.
   index:        (input)(unmodified)(4-byte register)  The index of ptr_array of
                    the tree that is being modified.
   auxiliary:    (input)(modified)(8-byte register)
*/
	mov   (\u), \reg1
	cmp   $dummy, \reg1
	jne   0f
	mov   \v, ptr_array(, \index, 8)
	jmp   9f
0:
	cmp   \u, 8(\reg1)
	jne   0f
	mov   \v, 8(\reg1)
	jmp   9f
0:
	mov   \v, 16(\reg1)
9:
	mov   \reg1, (\v)
.endm


.macro GET_ALIGNMENT_DISTANCE  alignment, address, summand, distance
/* Calculates the distance from (address + summand) to the nearest greater than
   or equal to address that is aligned to alignment bytes.  Uses %rax and %rdx.
   ( Distance = (Alignment-(address+summand)%Alignment)%Alignment )
   alignment:     (input)(unmodified)(8-byte register)
   address:       (input)(unmodified)(8-byte register)  The address whose next
                     distance to next aligned address will be calculated.
   summand:       (immediate)
   distance:      (output)(8-byte register)  The calculated distance.
*/
	mov   \address, %rax
	add   $\summand, %rax
	xor   %rdx, %rdx
	div   \alignment
	mov   \alignment, %rax
	sub   %rdx, %rax
	xor   %rdx, %rdx
	div   \alignment
	mov   %rdx, \distance
	
.endm


/***********************************PRIVATE*************************************
void add_block_to_system(void *block, int32 capacity)
Adds a small or medium block to the system.  Doesn't change the S or P bits.
*******************************************************************************/
add_block_to_system:

	cmp   $small_max, %esi
	jg    ADD_MEDIUM_BLOCK
/* ADD_BLOCK_SMALL: */
	CALCULATE_SMALL_INDEX %esi
	mov   ptr_array(, %esi, 8), %r11
	mov   %r11, (%rdi)                #block.next = list.head
	mov   %rdi, 8(%r11)               #list.head.prev = block
	mov   %rdi, ptr_array(, %esi, 8)  #list.head = block
	movq  $dummy, 8(%rdi)             #block.prev = dummy
	jmp   ADD_BLOCK_RETURN
ADD_MEDIUM_BLOCK:
	movq  $dummy, 32(%rdi)                #block.prev = dummy
	mov   %esi, %r11d
	CALCULATE_MEDIUM_INDEX %r11d          #r11d = ptr_array index
	mov   ptr_array(, %r11d, 8), %r10     #r10 = ptr to tree's root
	cmp   $dummy, %r10
	je    EMPTY_TREE
	mov   %r10, %rdx                      #save root in rdx for later
	RB_SEARCH %esi, %r10, %r9, %r8, %ecx  #r10=foundNodeP r9=prntP r8=side
	mov   %r9, (%rdi)                     #connect block w/ node.parent
	test  %r8, %r8                        # ''
	jz    1f                              # ''
	mov   %rdi, 16(%r9)                   # ''
	jmp   2f                              # ''
1:
	mov   %rdi, 8(%r9)                    # ''
2:
	cmp   $dummy, %r10
	je    NODE_NOT_FOUND
/* NODE_FOUND:  Case--Node found in tree */
	mov   %r10, 24(%rdi)               #block.next = next
	mov   %rdi, 32(%r10)               #next.prev = block
	mov   8(%r10), %rcx                #connect block w/ node's left child
	mov   %rcx, 8(%rdi)                # ''
	mov   %rdi, (%rcx)                 # ''
	mov   16(%r10), %rcx               #connect block w/ node's right child
	mov   %rcx, 16(%rdi)               # ''
	mov   %rdi, (%rcx)                 # ''
	mov   -3(%r10), %rcx               #set block.color to node.color
	and   $0x4, %rcx                   # ''
	SET_COLOR %rdi, -3, %rcx           # ''
	cmp   $dummy, %r9                  #if node is root, set block as new root
	jne   ADD_BLOCK_RETURN             # ''
	mov   %rdi, ptr_array(, %r11d, 8)  # ''
	jmp   ADD_BLOCK_RETURN
NODE_NOT_FOUND:  /* Case--Node not found in tree, and tree is not empty */
	mov   %rdi, %r10
	movq  $dummy, 8(%r10)   #node.lchild = dummy
	movq  $dummy, 16(%r10)  #node.rchild = dummy
	movq  $dummy, 24(%r10)  #node.next = dummy
	orb   $0x4, -3(%r10)    #node.color = red
/* CLRS INSERT-FIXUP (r10 = z)*/
1:
	mov   (%r10), %r9      #r9 = z.p
	testb $0x4, -3(%r9)    #while z.p.color == RED (clrs line 1)
	jz    1f               # ''
	mov   (%r9), %r8       #r8 = z.p.p
	cmp   %r9, 8(%r8)      #if z.p == z.p.p.left (clrs line 2)
	jne   2f               # ''
	mov   16(%r8), %rcx    #y = z.p.p.right (clrs line 3)
	testb $0x4, -3(%rcx)   #if y.color == RED (clrs line 4)
	jz    3f               # ''
	andb  $0xFB, -3(%r9)   #z.p.color = BLACK (clrs line 5)
	andb  $0xFB, -3(%rcx)  #y.color = BLACK (clrs line 6)
	orb   $0x4, -3(%r8)    #z.p.p.color = RED (clrs line 7)
	mov   %r8, %r10        #z = z.p.p (clrs line 8)
	jmp   1b
3:
	cmp   %r10, 16(%r9)    #else if z == z.p.right (clrs line 9)
	jne   3f               # ''
	LEFT_ROTATE 1, %r9, %r10, %rdx, %r11d, %rcx  #clrs lines 10-11
3:
	andb  $0xFB, -3(%r9)   #z.p.color = BLACK (clrs line 12)
	orb   $0x4, -3(%r8)    #z.p.p.color = RED (clrs line 13)
	RIGHT_ROTATE 0, %r8, %r9, %rdx, %r11d, %rcx  #clrs line 14
	jmp   1f
2:  /* clrs line 15 else mirrored case */
	mov   8(%r8), %rcx     #y = z.p.p.left (clrs line 3)(mirrored case)
	testb $0x4, -3(%rcx)   #if y.color == RED (clrs line 4)(mirrored case)
	jz    3f               # ''
	andb  $0xFB, -3(%r9)   #z.p.color = BLACK (clrs line 5)(mirrored case)
	andb  $0xFB, -3(%rcx)  #y.color = BLACK (clrs line 6)(mirrored case)
	orb   $0x4, -3(%r8)    #z.p.p.color = RED (clrs line 7)(mirrored case)
	mov   %r8, %r10        #z = z.p.p (clrs line 8)(mirrored case)
	jmp   1b
3:
	cmp   %r10, 8(%r9)     #else if z == z.p.left (clrs line 9)(mirrored case)
	jne   3f               # ''
	RIGHT_ROTATE 1, %r9, %r10, %rdx, %r11d, %rcx  #clrs lines 10-11(mirrored case)
3:
	andb  $0xFB, -3(%r9)   #z.p.color = BLACK (clrs line 12)(mirrored case)
	orb   $0x4, -3(%r8)    #z.p.p.color = RED (clrs line 13)(mirrored case)
	LEFT_ROTATE 0, %r8, %r9, %rdx, %r11d, %rcx  #clrs line 14(mirrored case)
	jmp   1f
1: 
	andb  $0xFB, -3(%rdx)  #T.root.color = BLACK (clrs line 16)
	jmp   ADD_BLOCK_RETURN
/* END CLRS INSERT-FIXUP */
EMPTY_TREE:  /* Case--Node not found in tree, and tree is empty */
	movq  $dummy, (%rdi)               #node.parent = dummy
	movq  $dummy, 8(%rdi)              #node.lchild = dummy
	movq  $dummy, 16(%rdi)             #node.rchild = dummy
	movq  $dummy, 24(%rdi)             #node.next = dummy
	andb  $0xFB, -3(%rdi)              #node.color = black
	mov   %rdi, ptr_array(, %r11d, 8)  #set node and the root via ptr_array
ADD_BLOCK_RETURN:
	ret


/***********************************PRIVATE*************************************
void remove_block_from_system(void *block, int32 capacity)
Removes a small or medium block to the system.  Doesn't change the S or P bits.
*******************************************************************************/
remove_block_from_system:

	cmp   $small_max, %esi
	jg    REMOVE_MEDIUM
/* REMOVE_SMALL: */
	mov   (%rdi), %r11   #r11 = next
	mov   8(%rdi), %r10  #r10 = prev
	mov   %r10, 8(%r11)  #next.prev = prev
	cmp   $dummy, %r10   
	je    1f
	/* case--block is not the head of the list */
	mov   %r11, (%r10)   #prev.next = next
	jmp   REMOVE_RETURN
1:  /* case--block is the head of the list */
	CALCULATE_SMALL_INDEX %esi
	mov   %r11, ptr_array(, %esi, 8)  #set list's head ptr (case block is head)
	jmp   REMOVE_RETURN
REMOVE_MEDIUM:
	/* check if the block is the only block in its tree node */
	mov   24(%rdi), %r11  #r11 = next
	mov   32(%rdi), %r10  #r10 = prev
	cmp   $dummy, %r10
	jne   REMOVE_MEDIUM_BLOCK_HAS_PREV
	cmp   $dummy, %r11
	jne   REMOVE_MEDIUM_BLOCK_LIST_HEAD_HAS_NEXT
/* CLRS_RB_DELETE: (rdi = z)*/
	CALCULATE_MEDIUM_INDEX %esi  #esi = index
	mov   %rdi, %r11        #r11 = y = z (clrs line 1)
	mov   -3(%r11), %r10    #r10 = y-original-color = y.color (clrs line 2)
	cmpq  $dummy, 8(%rdi)   #if x.left == T.nil (clrs line 3)
	jne   1f                # ''
	mov   16(%rdi), %r9     #r9 = x = z.right (clrs line 4)
	RB_TRANSPLANT %rdi,%r9,%esi,%rdx  #RB-TRANSPLANT(T,z,z.right) (clrs line 5)
	jmp   2f
1:
	cmpq  $dummy, 16(%rdi)  #elseif z.right == T.nil (clrs line 6)
	jne   1f                # ''
	mov   8(%rdi), %r9      #r9 = x = z.left (clrs line 7)
	RB_TRANSPLANT %rdi,%r9,%esi,%rdx  #RB-TRANSPLANT(T,z,z.left) (clrs line 8)
	jmp   2f
1:
	/* else y = TREE-MINMUM(z.right) (clrs line 9) */
	mov   16(%rdi), %r8     #r8 = z.right
1:
	cmpq  $dummy, 8(%r8)    #while x.left != NIL (clrs TREE-MINIMUM line 1)
	je    1f                # ''
	mov   8(%r8), %r8       #x = x.left (clrs TREE-MINIMUM line 2)
	jmp   1b
1:
	mov   %r8, %r11         #y = TREE-MINIMUM(z.right)
	mov   -3(%r11), %r10    #r10 = y-original-color = y.color (clrs line 10)
	mov   16(%r11), %r9     #x = y.right (clrs line 11)
	cmp   (%r11), %rdi      #if y.p == z (clrs line 12)
	jne   1f                # ''
	mov   %r11, (%r9)       #x.p = y (clrs line 13)
	jmp   3f
1:
	RB_TRANSPLANT %r11,%r9,%esi,%rdx  #RB-TRANSPLANT(T,y,y.right) (clrs line 14)
	mov   16(%rdi), %r8     #r8 = z.right
	mov   %r8, 16(%r11)     #y.right = z.right (clrs line 15)
	mov   %r11, (%r8)       #y.right.p = y (clrs line 16)
3:
	RB_TRANSPLANT %rdi,%r11,%esi,%rdx  #RB-TRANPLANT(T,z,y) (clrs line 17)
	mov   8(%rdi), %r8     #r8 = z.left
	mov   %r8, 8(%r11)     #y.left = z.left (clrs line 18)
	mov   %r11, (%r8)      #y.left.p = y (clrs line 19)
	mov   -3(%rdi), %r8    #y.color = z.color (clrs line 20)
	and   $0x4, %r8        # ''
	SET_COLOR %r11,-3,%r8  # ''
2:
	and   $0x4, %r10       #if y-original-color == BLACK (clrs line 21)
	jnz   REMOVE_RETURN    # ''
	/* RB-DELETE_FIXUP (clrs line 22) */
	mov   ptr_array(, %esi, 8), %r8  #r8 = root
1:
	cmp   %r8, %r9         #while x!= T.root and x.color == BLACK (clrs line 1)
	je    1f               # ''
	testb $0x4, -3(%r9)    # ''
	jnz   1f               # ''
	mov   (%r9), %rcx      #rcx = x.p
	cmp   8(%rcx), %r9     #if x == x.p.left (clrs line 2)
	jne   2f               # ''
	mov   16(%rcx), %r11   #r11 = w = x.p.right (clrs line 3)
	testb $0x4, -3(%r11)   #if w.color == RED (clrs line 4)
	jz    3f               # ''
	andb  $0xFB, -3(%r11)  #w.color = BLACK (clrs line 5)
	orb   $0x4, -3(%rcx)   #x.p.color = RED (clrs line 6)
	LEFT_ROTATE 0,%rcx,%r11,%r8,%esi,%rdx  #LEFT-ROTATE(T,x.p) (clrs line 7)
	mov   16(%rcx), %r11   #w = x.p.right (clrs line 8)
3:
	mov   8(%r11), %rdx    #rdx = w.left
	mov   16(%r11), %r10   #r10 = w.right
	testb $0x4, -3(%rdx)   #if w.left.color == BLACK and w.right.color == BLACK (clrs line 9)
	jnz   3f               # ''
	testb $0x4, -3(%r10)   # ''
	jnz   3f               # ''
	orb   $0x4, -3(%r11)   #w.color = RED (clrs line 10)
	mov   %rcx, %r9        #x = x.p
	jmp   1b
3:
	testb $0x4, -3(%r10)   #else if w.right.color == BLACK (clrs line 12)
	jnz   3f               # ''
	andb  $0xFB, -3(%rdx)  #w.left.color = BLACK (clrs line 13)
	orb   $0x4, -3(%r11)   #w.color = RED (clrs line 14)
	RIGHT_ROTATE 0,%r11,%rdx,%r8,%esi,%rdi  #RIGHT-ROTATE(T,w) (clrs line 15)
	mov   16(%rcx), %r11   #w = x.p.right (clrs line 16)
3:
	mov   -3(%rcx), %rdx   #rdx = x.p.color
	and   $0x4, %rdx       # ''
	SET_COLOR %r11,-3,%rdx #w.color = x.p.color (clrs line 17)
	andb  $0xFB, -3(%rcx)  #x.p.color = BLACK (clrs line 18)
	mov   16(%r11), %r10   #r10 = w.right
	andb  $0xFB, -3(%r10)  #w.right.color = BLACK (clrs line 19)
	LEFT_ROTATE 0,%rcx,%r11,%r8,%esi,%rdx  #LEFT-ROTATE(T,x.p) (clrs line 20)
	mov   %r8, %r9         #x = T.root (clrs line 21)
	jmp   1b
2:  /* else (same as then clause with "right" and "left" exchanged) (clrs line 22) */
	mov   8(%rcx), %r11    #r11 = w = x.p.left (clrs line 3)
	testb $0x4, -3(%r11)   #if w.color == RED (clrs line 4)
	jz    3f               # ''
	andb  $0xFB, -3(%r11)  #w.color = BLACK (clrs line 5)
	orb   $0x4, -3(%rcx)   #x.p.color = RED (clrs line 6)
	RIGHT_ROTATE 0,%rcx,%r11,%r8,%esi,%rdx  #RIGHT-ROTATE(T,x.p) (clrs line 7)
	mov   8(%rcx), %r11    #w = x.p.left (clrs line 8)
3:
	mov   16(%r11), %rdx   #rdx = w.right
	mov   8(%r11), %r10    #r10 = w.left
	testb $0x4, -3(%rdx)   #if w.right.color == BLACK and w.left.color == BLACK (clrs line 9)
	jnz   3f               # ''
	testb $0x4, -3(%r10)   # ''
	jnz   3f               # ''
	orb   $0x4, -3(%r11)   #w.color = RED (clrs line 10)
	mov   %rcx, %r9        #x = x.p
	jmp   1b
3:
	testb $0x4, -3(%r10)   #else if w.left.color == BLACK (clrs line 12)
	jnz   3f               # ''
	andb  $0xFB, -3(%rdx)  #w.right.color = BLACK (clrs line 13)
	orb   $0x4, -3(%r11)   #w.color = RED (clrs line 14)
	LEFT_ROTATE 0,%r11,%rdx,%r8,%esi,%rdi  #LEFT-ROTATE(T,w) (clrs line 15)
	mov   8(%rcx), %r11    #w = x.p.left (clrs line 16)
3:
	mov   -3(%rcx), %rdx   #rdx = x.p.color
	and   $0x4, %rdx       # ''
	SET_COLOR %r11,-3,%rdx #w.color = x.p.color (clrs line 17)
	andb  $0xFB, -3(%rcx)  #x.p.color = BLACK (clrs line 18)
	mov   8(%r11), %r10    #r10 = w.left
	andb  $0xFB, -3(%r10)  #w.left.color = BLACK (clrs line 19)
	RIGHT_ROTATE 0,%rcx,%r11,%r8,%esi,%rdx  #RIGHT-ROTATE(T,x.p) (clrs line 20)
	mov   %r8, %r9         #x = T.root (clrs line 21)
	jmp   1b
1:
	andb  $0xFB, -3(%r9)    #x.color = BLACK (clrs line 23)
	jmp   REMOVE_RETURN
	/* END RB-DELETE-FIXUP */
REMOVE_MEDIUM_BLOCK_HAS_PREV:
	mov   %r10, 32(%r11)   #next.prev = prev
	mov   %r11, 24(%r10)   #prev.next = next
	jmp   REMOVE_RETURN
REMOVE_MEDIUM_BLOCK_LIST_HEAD_HAS_NEXT:
	movq  $dummy, 32(%r11)                #next.prev = dummy
	CALCULATE_MEDIUM_INDEX %esi
	RB_TRANSPLANT %rdi, %r11, %esi, %rdx  #connect next with block.parent
	mov   8(%rdi), %r9                    #connect next with block.lchild
	mov   %r11, (%r9)                     # ''
	mov   %r9, 8(%r11)                    # ''
	mov   16(%rdi), %r9                   #connect next with block.rchild
	mov   %r11, (%r9)                     # ''
	mov   %r9, 16(%r11)                   # ''
	mov   -3(%rdi), %r9                   #next.color = block.color
	and   $0x4, %r9                       # ''
	SET_COLOR %r11, -3, %r9               # ''
REMOVE_RETURN:
	ret


/************************************PUBLIC*************************************
int64 ja_init(void)
Must be called once and only once before using ja_allocate or ja_free. It
initializes ptr_array with the address of dummy, properly aligns the break,
finds out and saves the page size, and allocates a wilderness block.
Returns 0 on success and 1 on SET_BREAK failure.
*******************************************************************************/
.global ja_init
ja_init:

	/* Initialize ptr_array with dummy's ptr */
	xor   %r11, %r11
1:
	cmp  $ptr_array_max_index, %r11
	jg    1f
	mov   $dummy, %r10
	mov   $ptr_array, %r9
	movq   $dummy, (%r9)
	mov   %r10, ptr_array
	movq  %r10, ptr_array(, %r11, 8)
	inc   %r11
	jmp   1b
1:
	GET_BREAK
	/* Adjust the break, if necessary, so that (break+3) is 8-byte aligned. We
	   do this by adding the following to the break: (8-(break+3)%8)%8 */
	mov   $8, %r11
	mov   %rax, %rcx  #preserve rax across next line's macro
	GET_ALIGNMENT_DISTANCE %r11 %rax 3 %rdi
	mov   %rcx, %rax
	add   %rdi, %rax
	SET_BREAK %rax
	/* System-allocate a chunk of minimum size to make the wilderness */
	mov   $min_chunk_size, %rdi
	add   %rax, %rdi
	SET_BREAK %rdi
	/* Fill in capacity in the footer of the wilderness */
	mov   $min_capacity, %r11  #$r11 = capacity
	ADD_CAPACITY_TO_FOOTER %r11d %rax -4
	/* Fill in capacity in the header of the wilderness */
	ADD_CAPACITY_TO_HEADER %r11d %rax -24
	/* Set P-bit in header (to prevent future coalescing attempts of 
	   predecessor) */
	orb   $0x1, -24(%rax)
	/* Set wilderness pointer */
	sub   $min_capacity, %rax
	mov   %rax, wilderness_ptr
	/* Find out and store the page size */
	mov   $30, %rdi
	call  sysconf
	mov   %rax, page_size

	xor   %rax, %rax
	ret


/************************************PUBLIC*************************************
int ja_allocate(void **ptr, int requested_capacity)
Returns 0 on success, 1 on SET_BREAK error.
*******************************************************************************/
.global ja_allocate
ja_allocate:

	/* Prologue */
	push  %rbx
	push  %r12
	push  %r13
	push  %r14
	push  %r15

	mov   %rdi, %r12  #r12 will hold the ptr arg for entire function length

	/* Branch depending on the size-class of the requested block */
	cmp   $small_max, %rsi
	jle   ALLOC_SMALL 
	cmp   $medium_max, %rsi
	jle   ALLOC_MEDIUM
	jmp   ALLOC_LARGE

ALLOC_SMALL:  #attempt to find a fitting chunk of small size-class
	/* Find the maximum of requested_capacity and min_capacity. This will be the
	   capacity minus the padding, or the initial capacity. */
	mov   $min_capacity, %r11
	cmp   %r11, %rsi
	cmovl %r11, %rsi  #%rsi = (initial capacity)
	mov   $8, %r11
	GET_ALIGNMENT_DISTANCE %r11, %rsi, 3, %r13
	/* Calculate ideal block capacity */
	add   %rsi, %r13  #%r13 = (initial capacity)+padding = (ideal capacity)
	/* Calculate the starting index for the ptr_array to start searching at.
	   This is (ideal capacity)/8-2 */
	mov   %r13, %r11
	CALCULATE_SMALL_INDEX %r11d
	/* Using the starting index just found, loop through the small-class array
	   portion to find a non-empty list */
1:
	cmp  $ptr_array_small_max_index, %r11
	jg ALLOC_MEDIUM_FROM_SMALL
	mov   ptr_array(,%r11,8), %rbx
	cmp   $dummy, %rbx
	jnz   1f
	inc   %r11
	jmp   1b
1:
	/* Remove the head node from the non-empty list that was found. */
	mov   (%rbx), %r9
	mov   %r9, ptr_array(,%r11,8)
	movq  $dummy, 8(%r9)
1:

SPLIT_AND_FINISH:  /* Calculate leftover amount in the block and split if big
	   enough.  Expects that %rbx=(block address) and %r13=(ideal capacity) */
	EXTRACT_BLOCK_INFO 0 %rbx -3 %r10d
	mov   %r10, %rcx
	sub   %r13, %r10  
	sub   $3, %r10  
	cmp   $min_capacity, %r10
	jl    2f  
	/* Fill in the new capacity in the final block's header */
	sub   %r10, %rcx
	sub   $3, %rcx
	ADD_CAPACITY_TO_HEADER_KEEP_BITS %ecx %rbx -3
	/* Fill in the capacity in the leftover block's header */
	lea   3(%rbx,%rcx), %r8 
	ADD_CAPACITY_TO_HEADER %r10d %r8 -3
	/* Fill in the capacity in the leftover block's footer */
	lea   -4(%r8, %r10), %rdx  
	ADD_CAPACITY_TO_FOOTER %r10d %rdx 0
	/* Update wilderness pointer if the found block was wilderness(split is now)
	   */
	cmp   wilderness_ptr, %rbx
	jnz   1f
	movq  %r8, wilderness_ptr
	jmp   2f
1:
	/* Add the leftover block to the memory system */
	mov   %r8, %rdi
	mov   %r10, %rsi
	push  %rcx
	call  add_block_to_system
	pop   %rcx
2:
	/* Fill in the S bit and the successor's P-bit of the final block */
	orb   $2, -3(%rbx)
	cmp   wilderness_ptr, %rbx
	jz    1f
	orb   $1, (%rbx, %rcx)
1:
	/* Return the pointer to the final block */
	mov   %rbx, %rax
	jmp   ALLOC_RETURN

ALLOC_MEDIUM:
	/* Calculate padding; add it to capacity to create ideal capacity */
	mov   $8, %r10
	GET_ALIGNMENT_DISTANCE %r10 %rsi 3 %r13
	add   %rsi, %r13  #%r13 = ideal capacity
	/* Calculate starting index */
	mov   %r13, %r11
	CALCULATE_MEDIUM_INDEX %r11
ALLOC_MEDIUM_FROM_SMALL:  #loop exit after unsuccessful search of small lists
1:
	cmp   $ptr_array_max_index, %r11
	jg    NOT_FOUND_IN_SMALL_OR_MEDIUM
	cmpq  $dummy, ptr_array(, %r11, 8)
	je    2f
	mov   ptr_array(, %r11, 8), %rbx
	RB_SEARCH %r13d, %rbx, %r10, %r9, %r8d
	cmp   $dummy, %rbx
	jnz   5f  #a fitting capacity block was found
	cmp   $0, %r9
	je    4f  #node is a left child; its parent is the (satisfying) successor
	/* find successor node */
	mov   %r10, %rbx
	mov   (%r10), %r10
3:
	cmp   $dummy, %r10
	je    2f  #successor not found
	cmp   8(%r10), %rbx
	je    4f  #node is a left child; its parent is the (satisfying) successor
	mov   %r10, %rbx
	mov   (%r10), %r10
	jmp   3b
4:  /* successor found */
	mov   %r10, %rbx
	jmp   5f
5:
	EXTRACT_BLOCK_INFO 0, %rbx, -3, %esi, %r10d
	mov   %rbx, %rdi
	call  remove_block_from_system
	jmp   SPLIT_AND_FINISH
2:  /* successor not found; tree not suitable */
	inc   %r11
	jmp   1b

NOT_FOUND_IN_SMALL_OR_MEDIUM:
	/* Check Wilderness */
	mov   wilderness_ptr, %r9
	mov   %r9, %rbx  #save (SPLIT_AND_FINISH requires found block ptr in %rbx)
	EXTRACT_BLOCK_INFO 2 %r9 -3 %r9d %r11d
	test  $0x2, %r11
	jnz   WILDERNESS_DOESNT_SATISFY
	cmp   %r13, %r9
	jge   SPLIT_AND_FINISH

WILDERNESS_DOESNT_SATISFY:  #wilderness was allocated or wasn't big enough
	/* Increase break to satisfy the allocation request and get more free chunks
	   */
	GET_BREAK
	mov   %r13, %rsi  #%rsi = ideal capacity
	add   $3, %rsi  #%rsi = ideal chunk size
	imul  $system_allocate_multiplier, %rsi  #%rsi = amount to add to break
	add   %rax, %rsi  #%rsi = new break
	SET_BREAK %rsi
	/* Set wilderness and (possibly)free old one */
	ADD_CAPACITY_TO_FOOTER %r13d %rax -4
	sub   %r13, %rax  #%rax = ptr to new wilderness block
	ADD_CAPACITY_TO_HEADER %r13d %rax -3
	orb   $0x1, -3(%rax)  #new wilderness' p-bit=1(2nd-to-last will be returned)
	mov   %rax, %r15  #save block ptr for later use
	mov   wilderness_ptr, %rsi
	EXTRACT_BLOCK_INFO 2 %rsi -3 %r10d %r11d
	test  $0x2, %r11
	jnz   WILDERNESS_IN_USE  #skip freeing the block if its in use
	/* add old wilderness block to system */
	mov   %rsi, %rdi
	mov   %r10, %rsi
	call  add_block_to_system
	jmp   1f
WILDERNESS_IN_USE:
	orb   $0x1, (%rsi,%r10,)  #set P-bit of old wilderness' successor
1:
	mov   %r15, wilderness_ptr  #set new wilderness ptr
	/* Skip the 2nd-to-last block (this will be the one that is returned to
	   user) */
	sub   %r13, %r15  #r15 points to 2nd-to-last block + 3
	sub   $3, %r15  #r15 points to 2nd to last block
	mov   %r15, %r14  #save for later
	/* Free the other blocks */
	mov   $2, %rbx
1:
	cmp   $system_allocate_multiplier, %rbx
	jge   1f
	ADD_CAPACITY_TO_FOOTER %r13d %r15 -7
	sub   %r13, %r15
	ADD_CAPACITY_TO_HEADER_KEEP_BITS %r13d %r15 -6
	sub   $3, %r15
	/* add block to system */
	mov   %r15, %rdi
	mov   %r13, %rsi
	call  add_block_to_system
	inc   %rbx
	jmp   1b
1:
	/* Set the 2nd-to-last block as the one to return to the user */
	mov   %r14, %rax
	ADD_CAPACITY_TO_HEADER_KEEP_BITS %r13d %r14 -3
	orb   $0x2, -3(%r14)  #fill in S-bit in header
	andb  $0xFB, -3(%r14)  #fill in C-bit in header
	jmp   ALLOC_RETURN

ALLOC_LARGE:
	/* Round (capacity + 14) up to the nearest page size */
	mov   %rsi, %r13  #preserve capacity across syscall
	add   $14, %rsi
	mov   page_size, %r11
	GET_ALIGNMENT_DISTANCE %r11 %rsi 0 %r10
	add   %r10, %rsi
	/* call mmap */
	xor   %rdi, %rdi
	mov   $3, %rdx
	mov   $34, %rcx
	xor   %r8, %r8
	xor   %r9, %r9
	call  mmap
	/* use the return value to calculate padding. */
	mov   %rax, %rcx
	mov   $8, %r11
	GET_ALIGNMENT_DISTANCE %r11 %rax 7 %r10  #r10 = padding
	/* fill in capacity in header */
	add   %r10, %rcx  #rcx points to header
	add   $7, %rcx
	ADD_CAPACITY_TO_HEADER %r13d %rcx -3
	/* set C-bit */
	orb  $0x4, -3(%rcx)
	/* store the padding amount in the header's capacity section. */
	shl   $3, %r10
	or    %r10b, -3(%rcx)  #note: mmap anonymous mapping zeroed out all bytes
	mov   %rcx, %rax
	
ALLOC_RETURN:
	mov   %rax, (%r12)
	/* Epilogue */
	pop   %r15
	pop   %r14
	pop   %r13
	pop   %r12
	pop   %rbx
	xor   %rax, %rax
	ret


/************************************PUBLIC*************************************
int ja_free(void *block_ptr)
Returns 0 on success, and 1 on SET_BREAK error.
*******************************************************************************/
.global ja_free
ja_free:

	/* Prologue */
	push  %rbx  #rbx is used as the ptr to the block that is to be freed
	push  %r15  #r15 is used as the capacity of the block
	sub   $8, %rsp

	/* extract info and jump if large */
	EXTRACT_BLOCK_INFO 2 %rdi -3 %r15d %r10d
	test  $0x4, %r10
	jnz   FREE_LARGE

	/* Coalesce with preceding chunk if the predecessor is free and the sum of
	   their capacities(+3) is within the range of small or medium blocks */
	mov   %rdi, %rbx  #rbx = block ptr
	test  $0x1, %r10d
	jnz   SKIP_PREDECESSOR_COALESCING
	EXTRACT_BLOCK_INFO 0 %rbx -6 %r11d
	mov   %r11, %r10  #r10 = pred capacity
	add   %r15, %r11  
	add   $3, %r11  #r11 = combined capacity
	cmp   $medium_max, %r11
	jg    SKIP_PREDECESSOR_COALESCING
	sub   %r10, %rbx  #rbx = pred block ptr + 3
	sub   $3, %rbx
	push  %r11
	push  %rdi
	mov   %rbx, %rdi
	mov   %r10, %rsi
	call  remove_block_from_system
	pop   %rdi
	pop   %r11
	mov   %r11, %r15  #r15 = combined capacity
	
SKIP_PREDECESSOR_COALESCING:
	/* if (self == wilderness) THEN set wilderness_ptr to head AND jump to SKIP
	   */
	cmpq wilderness_ptr, %rdi
	jnz 1f
	movq %rbx, wilderness_ptr
	jmp SKIP_SUCCESSOR_COALESCING
	
1:
	/* if (successor is free and the capacity sum is less than limit) THEN
	   capacity += capacity successor 
	   AND if (successor == wilderness) THEN set wilderness_ptr to head AND
	   jump to SKIP
	   -Call remove on successor and set succ. p-bit */
	lea   3(%rbx, %r15), %r11  #r11 = successor's block ptr
	andb  $0xFE, -3(%r11)
	EXTRACT_BLOCK_INFO 2 %r11 -3 %r10d %r9d
	test   $0x2, %r9d
	jnz   SKIP_SUCCESSOR_COALESCING
	mov   %r10, %r9
	add   %r15, %r10
	add   $3, %r10  #r10 = combined capacity
	cmp   $medium_max, %r10
	jg    SKIP_SUCCESSOR_COALESCING
	mov   %r10, %r15
	cmp   wilderness_ptr, %r11
	jnz   1f
	mov   %rbx, wilderness_ptr
	jmp   SKIP_SUCCESSOR_COALESCING
1:
	mov   %r11, %rdi
	mov   %r9, %rsi
	call  remove_block_from_system

SKIP_SUCCESSOR_COALESCING:
	/* Set capacity and S-bit in header and footer */
	ADD_CAPACITY_TO_HEADER_KEEP_BITS %r15d %rbx -3
	andb  $0xFD, -3(%rbx)
	lea   (%r15, %rbx), %r9
	ADD_CAPACITY_TO_FOOTER_KEEP_BITS %r15 %r9 -4
	/* IF wilderness THEN attempt to trim wilderness */
	cmp   wilderness_ptr, %rbx
	jnz   1f
	cmp   $wilderness_trim_threshold, %r15
	jle   FREE_RETURN
	mov   %rbx, %rdi
	add   $min_capacity, %rdi
	SET_BREAK %rdi
	mov   $min_capacity, %rcx
	ADD_CAPACITY_TO_HEADER_KEEP_BITS %ecx %rbx -3
	ADD_CAPACITY_TO_FOOTER_KEEP_BITS %ecx %rbx 17
	jmp FREE_RETURN
1:  /* Not wilderness, so set P bit in final successor's header, and add
	   block to system */
	leaq  (%r15, %rbx), %r10
	andb  $0xFE, (%r10)
	mov   %rbx, %rdi
	mov   %r15, %rsi
	call  add_block_to_system
	jmp FREE_RETURN

FREE_LARGE:
	xor   %r10, %r10
	movb  -3(%rdi), %r10b
	shr   $3, %r10  #r10 = padding amount
	mov   -7(%rdi), %esi  #esi = capacity
	mov   page_size, %r9
	add   $14, %rsi
	GET_ALIGNMENT_DISTANCE %r9, %rsi, 0, %r8
	add   %r8, %rsi
	sub   $7, %rdi
	sub   %r10, %rdi
	call  munmap

FREE_RETURN:
	/* Epilogue */
	add   $8, %rsp
	pop   %r15
	pop   %rbx
	xor   %rax, %rax
	ret

