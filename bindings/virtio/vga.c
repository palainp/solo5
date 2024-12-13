/*
 * This file is taken/largely inspired from: https://github.com/FRosner/FrOS
 * based on https://github.com/cfenollosa/os-tutorial which is licenced under BSD-3-Clause
 *
 * The purpose is to serve as a naive VGA console when you need to print and serial is not
 * usable.
 */

#include "bindings.h"

#define VIDEO_ADDRESS  0xb8000
#define COLOR          0x0f /* white on black */
#define MAX_COLS       80
#define MAX_ROWS       25

/*
 * The cursor position is defined as an offset in memory. Each character
 * use two bytes, one for the character and another for the color encoding.
 * Therefore we can use the following conversions:
 *   offset -> position x,y:
 *     x = (offset/2) % MAX_COLS
 *     y = (offset/2) / MAX_COLS
 *   position x,y -> offset:
 *     offset = 2 * (y*MAX_COLS + x)
 * The 2B for x,y + 1 bit for the "offsetation" doesn't fit into a 16B,
 * so far we can use a 32b value...
 */

typedef uint32_t offset_t;

#define VGA_CTRL_REGISTER 0x3d4
#define VGA_DATA_REGISTER 0x3d5
#define VGA_OFFSET_LOW    0x0f
#define VGA_OFFSET_HIGH   0x0e

static void set_cursor(offset_t offset)
{
    offset /= 2;
    outb(VGA_CTRL_REGISTER, VGA_OFFSET_HIGH);
    outb(VGA_DATA_REGISTER, (unsigned char) (offset >> 8));
    outb(VGA_CTRL_REGISTER, VGA_OFFSET_LOW);
    outb(VGA_DATA_REGISTER, (unsigned char) (offset & 0xff));
}

static offset_t get_cursor()
{
    outb(VGA_CTRL_REGISTER, VGA_OFFSET_HIGH);
    offset_t offset = inb(VGA_DATA_REGISTER) << 8;
    outb(VGA_CTRL_REGISTER, VGA_OFFSET_LOW);
    offset |= inb(VGA_DATA_REGISTER);
    return offset * 2;
}

// returns the current offset in memory (as defined in the top comment)
static offset_t get_offset(uint8_t col, uint8_t row)
{
    return 2 * (row * MAX_COLS + col);
}

// writes the char c at offset
static void set_char_at_video_memory(char c, offset_t offset)
{
    unsigned char *vidmem = (unsigned char *) VIDEO_ADDRESS;
    vidmem[offset] = c;
    vidmem[offset + 1] = COLOR;
}

// all the screen goes up 1 line and the last line is blanked
static offset_t scroll()
{
    memcpy(
        (void*) ((uintptr_t)get_offset(0, 0) + VIDEO_ADDRESS),
        (void*) ((uintptr_t)get_offset(0, 1) + VIDEO_ADDRESS),
        MAX_COLS * (MAX_ROWS - 1) * 2
    );

    for (offset_t col = get_offset(0, MAX_ROWS - 1);
            col < get_offset(MAX_COLS, MAX_ROWS - 1);
            col += 2) {
        set_char_at_video_memory(' ', col);
    }

    return get_offset(0, MAX_ROWS - 1);
}

// clear the screen
void vga_clear()
{
    for (offset_t i = 0; i < MAX_COLS * MAX_ROWS; i += 2) {
        set_char_at_video_memory(' ', i);
    }
    set_cursor(get_offset(0, 0));
}

// adds the character c at the current position and updates the current position
void vga_putc(char c)
{
    offset_t offset = get_cursor();
    if (offset >= MAX_ROWS * MAX_COLS * 2) {
        offset = scroll(offset);
    }
    switch (c) {
        offset_t row, col;
        case '\n':
            row = offset / (2 * MAX_COLS);
            // offset_t col = offset % (2 * MAX_COLS);
            // offset = get_offset(col, row + 1);
            offset = get_offset(0, row + 1); // the UNIX '\n'
            break;
        case '\r':
            row = offset / (2 * MAX_COLS);
            offset = get_offset(0, row);
            break;
        case '\t':
            // write spaces until next 'multiple of 8' position
            col = offset % (2 * MAX_COLS);
            for (offset_t i = col%8; i < 8; ++i)
            {
                set_char_at_video_memory(' ', offset);
                offset += 2;
                if (offset >= MAX_ROWS * MAX_COLS * 2) {
                    offset = scroll(offset);
                }
            }
            break;
        default:
            set_char_at_video_memory(c, offset);
            offset += 2;
    }
    set_cursor(offset);
}
