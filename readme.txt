Overview:

jalloc is a heap memory allocator written in x86-64 assembly language.  It is 
intended to be used by little endian machines running linux, and assembled
and linked using gcc.  It provides the functionality of malloc and free, but
has a different interface.  Regardless of allocation and deallocation patterns,
the speed of each allocation and deallocation is at most O(log n), which is 
comparible to most popular allocators.  Memory usage is reasonable, as the 
design uses techniques to reduce internal and external memory fragmentation.
The three main functions provided are the following:

void ja_init(void)
This must be called once and only once before using mm_allocate.

int ja_allocate(void **p, int size)
"p" must be a pointer to the pointer that will point to the allocated memory
block.  "size" must be a positive integer less than 2^32 that indicates the 
number of bytes you wish to have allocated.  A return value of 0 indicates 
success, while a positive integer indicates a failure.

int ja_free(void *p)
"p" must be a pointer pointing to a block that was allocated with mm_allocate,
and which hasn't yet been freed.  A return value of 0 indicates success, while a
positive integer indicates a failure.



Internal Design Features:

The following discussion will call the user-usable portion of the allocated
memory a block.  The capacity refers to the size (in bytes) of a block,
which is at least the size requested by the user in the call to ja_allocate.
Directly preceding every block is a 3 byte header, containing the capacity and
three bits called the c-bit, the s-bit, and the p-bit, which hold additional
information.  Sometimes, following the block is unused padding, which is 
followed by a footer that is a mirror of the header.  The block, along with its
header and footer, is called a chunk.

The chunks are treated differently by the allocator depending on the 
size class of the chunks.  Each chunk is considered either small, medium, or
large depending of its capacity.  Small and medium chunks differ from one
another in only the method in which the allocator stores them when they are
free (not allocated to the user).

The free small chunks are organized in 126 linked lists.  Each list holds chunks
of a fixed capacity, and the lists' chunks's capacities are spaced 8 bytes 
apart.  This allows small allocations to be satisfied extremely quickly by just
finding a non-empty list that is large enough, and removing the head of the list.

The free medium chunks have a much wider range in capacity than small ones, so
fixed size lists are not feasible.  Instead, the chunks are organized into
red-black trees, which offer a slightly slower, but scalable solution.

Small/medium chunks differ from large chunks two ways.  Large chunks are
internally allocated from the operating system using mmap, while the 
small/medium chunks use brk.  Secondly, small/medium chunks and large chunks
have slightly different headers and footers, which can be seen in the chunk
layout below.

In order to prevent unnecessary fragmentation, chunks are attempted to be split
during allocation, and coalesced with adjacent chunks during deallocation.
Memory is further protected by monitoring the chunk at the end of the heap.  If
it exceeds a certain size, a call to brk is made to reduce the size of the heap.



Chunk Layout:

Note- For small/medium blocks, the s in s-bit stands for self and is 1 if the
block is allocated and 0 if it is free.  The p in p-bit stands for previous, and
is 1 if the previous(adjacent in memory) block is allocated and 0 if it is free.

SMALL

Chunk Start---(3)   Capacity/C(0 if allocated)/S/P
Block Start-|-(8)   Next Ptr
Capacity----| (8)   Prev Ptr
            |-(Capacity-16)
              (0-7) Padding
              (3)   Capacity/C(unused)/S/P(unused)

MEDIUM

Chunk Start---(3)   Capacity/C(0 if allocated;otherwise color)/S/P
Block Start-|-(8)   Parent Ptr
Capacity----| (8)   Left Child Ptr
            | (8)   Right Child Ptr
            | (8)   Next Ptr
            | (8)   Prev Ptr
            |-(Capacity-40)
              (0-7) Padding
              (3)   Capacity/C(unused)/S/P(unused)

LARGE

Chunk Start   (0-7) Padding
              (4)   Capacity
              (3)   Padding Amount/C(1)/S(unused)/P(unused)
Block Start   (Capacity)
              (?)   Padding to align chunk size along page size
