// Ghostty's internal embedder API, a.k.a. "libghostty-internal".
//
// The only consumer of this API is the macOS app, and while it is fairly
// comprehensive, it is tailored to the needs of the macOS app and not designed
// for external use, hence why most functions are undocumented and some are
// macOS-specific (e.g. ones dealing with the Metal graphics API).
// 
// External embedders should instead use `libghostty-vt` or other related
// packages, which are extensively documented and designed from the ground up
// to be used in other software. Header files for which can be found in
// `include/ghostty/`.
#ifndef GHOSTTY_H
#define GHOSTTY_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef _MSC_VER
#include <BaseTsd.h>
typedef SSIZE_T ssize_t;
#else
#include <sys/types.h>
#endif

//-------------------------------------------------------------------
// Macros

#define GHOSTTY_SUCCESS 0

// Symbol visibility for shared library builds. On Windows, functions
// are exported from the DLL when building and imported when consuming.
// On other platforms with GCC/Clang, functions are marked with default
// visibility so they remain accessible when the library is built with
// -fvisibility=hidden. For static library builds, define GHOSTTY_STATIC
// before including this header to make this a no-op.
#ifndef GHOSTTY_API
#if defined(GHOSTTY_STATIC)
  #define GHOSTTY_API
#elif defined(_WIN32) || defined(_WIN64)
  #ifdef GHOSTTY_BUILD_SHARED
    #define GHOSTTY_API __declspec(dllexport)
  #else
    #define GHOSTTY_API __declspec(dllimport)
  #endif
#elif defined(__GNUC__) && __GNUC__ >= 4
  #define GHOSTTY_API __attribute__((visibility("default")))
#else
  #define GHOSTTY_API
#endif
#endif

//-------------------------------------------------------------------
// Types

// Opaque types
typedef void* ghostty_app_t;
typedef void* ghostty_config_t;
typedef void* ghostty_surface_t;
typedef void* ghostty_inspector_t;

// All the types below are fully defined and must be kept in sync with
// their Zig counterparts. Any changes to these types MUST have an associated
// Zig change.
typedef enum {
  GHOSTTY_PLATFORM_INVALID,
  GHOSTTY_PLATFORM_MACOS,
  GHOSTTY_PLATFORM_IOS,
} ghostty_platform_e;

typedef enum {
  GHOSTTY_CLIPBOARD_STANDARD,
  GHOSTTY_CLIPBOARD_SELECTION,
  GHOSTTY_CLIPBOARD_PRIMARY,
} ghostty_clipboard_e;

// One representation of clipboard contents. The data is binary-safe with
// an explicit length; it is not necessarily null-terminated.
typedef struct {
  const char *mime;
  const char *data;
  size_t len;
} ghostty_clipboard_content_s;

// The payload for completing a clipboard read request. See
// ghostty_surface_complete_clipboard_request.
typedef struct {
  const ghostty_clipboard_content_s *contents;
  size_t contents_len;
  const char *const *available;
  size_t available_len;
  bool confirmed;
  bool remember;
} ghostty_clipboard_complete_s;

// The payload of a clipboard read confirmation request: the would-be
// completion contents plus the information shown in the permission
// prompt. See ghostty_runtime_confirm_read_clipboard_cb.
typedef struct {
  const ghostty_clipboard_content_s *contents;
  size_t contents_len;
  const char *const *available;
  size_t available_len;
  const char *name;
  bool can_remember;
} ghostty_clipboard_confirm_s;

typedef enum {
  GHOSTTY_CLIPBOARD_REQUEST_PASTE,
  GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
  GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
  GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ,
  GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE,
  GHOSTTY_CLIPBOARD_REQUEST_LIST,
} ghostty_clipboard_request_e;

// apprt.ClipboardReadResult
typedef enum {
  GHOSTTY_CLIPBOARD_READ_STARTED,
  GHOSTTY_CLIPBOARD_READ_UNAVAILABLE,
  GHOSTTY_CLIPBOARD_READ_UNSUPPORTED,
} ghostty_clipboard_read_result_e;

typedef enum {
  GHOSTTY_MOUSE_RELEASE,
  GHOSTTY_MOUSE_PRESS,
} ghostty_input_mouse_state_e;

typedef enum {
  GHOSTTY_MOUSE_UNKNOWN,
  GHOSTTY_MOUSE_LEFT,
  GHOSTTY_MOUSE_RIGHT,
  GHOSTTY_MOUSE_MIDDLE,
  GHOSTTY_MOUSE_FOUR,
  GHOSTTY_MOUSE_FIVE,
  GHOSTTY_MOUSE_SIX,
  GHOSTTY_MOUSE_SEVEN,
  GHOSTTY_MOUSE_EIGHT,
  GHOSTTY_MOUSE_NINE,
  GHOSTTY_MOUSE_TEN,
  GHOSTTY_MOUSE_ELEVEN,
} ghostty_input_mouse_button_e;

typedef enum {
  GHOSTTY_MOUSE_MOMENTUM_NONE,
  GHOSTTY_MOUSE_MOMENTUM_BEGAN,
  GHOSTTY_MOUSE_MOMENTUM_STATIONARY,
  GHOSTTY_MOUSE_MOMENTUM_CHANGED,
  GHOSTTY_MOUSE_MOMENTUM_ENDED,
  GHOSTTY_MOUSE_MOMENTUM_CANCELLED,
  GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN,
} ghostty_input_mouse_momentum_e;

typedef enum {
  GHOSTTY_COLOR_SCHEME_LIGHT = 0,
  GHOSTTY_COLOR_SCHEME_DARK = 1,
} ghostty_color_scheme_e;

// This is a packed struct (see src/input/mouse.zig) but the C standard
// afaik doesn't let us reliably define packed structs so we build it up
// from scratch.
typedef int ghostty_input_scroll_mods_t;

typedef enum {
  GHOSTTY_MODS_NONE = 0,
  GHOSTTY_MODS_SHIFT = 1 << 0,
  GHOSTTY_MODS_CTRL = 1 << 1,
  GHOSTTY_MODS_ALT = 1 << 2,
  GHOSTTY_MODS_SUPER = 1 << 3,
  GHOSTTY_MODS_CAPS = 1 << 4,
  GHOSTTY_MODS_NUM = 1 << 5,
  GHOSTTY_MODS_SHIFT_RIGHT = 1 << 6,
  GHOSTTY_MODS_CTRL_RIGHT = 1 << 7,
  GHOSTTY_MODS_ALT_RIGHT = 1 << 8,
  GHOSTTY_MODS_SUPER_RIGHT = 1 << 9,
} ghostty_input_mods_e;

typedef enum {
  GHOSTTY_BINDING_FLAGS_CONSUMED = 1 << 0,
  GHOSTTY_BINDING_FLAGS_ALL = 1 << 1,
  GHOSTTY_BINDING_FLAGS_GLOBAL = 1 << 2,
  GHOSTTY_BINDING_FLAGS_PERFORMABLE = 1 << 3,
} ghostty_binding_flags_e;

typedef enum {
  GHOSTTY_ACTION_RELEASE,
  GHOSTTY_ACTION_PRESS,
  GHOSTTY_ACTION_REPEAT,
} ghostty_input_action_e;

// Based on: https://www.w3.org/TR/uievents-code/
typedef enum {
  GHOSTTY_KEY_UNIDENTIFIED,

  // "Writing System Keys" § 3.1.1
  GHOSTTY_KEY_BACKQUOTE,
  GHOSTTY_KEY_BACKSLASH,
  GHOSTTY_KEY_BRACKET_LEFT,
  GHOSTTY_KEY_BRACKET_RIGHT,
  GHOSTTY_KEY_COMMA,
  GHOSTTY_KEY_DIGIT_0,
  GHOSTTY_KEY_DIGIT_1,
  GHOSTTY_KEY_DIGIT_2,
  GHOSTTY_KEY_DIGIT_3,
  GHOSTTY_KEY_DIGIT_4,
  GHOSTTY_KEY_DIGIT_5,
  GHOSTTY_KEY_DIGIT_6,
  GHOSTTY_KEY_DIGIT_7,
  GHOSTTY_KEY_DIGIT_8,
  GHOSTTY_KEY_DIGIT_9,
  GHOSTTY_KEY_EQUAL,
  GHOSTTY_KEY_INTL_BACKSLASH,
  GHOSTTY_KEY_INTL_RO,
  GHOSTTY_KEY_INTL_YEN,
  GHOSTTY_KEY_A,
  GHOSTTY_KEY_B,
  GHOSTTY_KEY_C,
  GHOSTTY_KEY_D,
  GHOSTTY_KEY_E,
  GHOSTTY_KEY_F,
  GHOSTTY_KEY_G,
  GHOSTTY_KEY_H,
  GHOSTTY_KEY_I,
  GHOSTTY_KEY_J,
  GHOSTTY_KEY_K,
  GHOSTTY_KEY_L,
  GHOSTTY_KEY_M,
  GHOSTTY_KEY_N,
  GHOSTTY_KEY_O,
  GHOSTTY_KEY_P,
  GHOSTTY_KEY_Q,
  GHOSTTY_KEY_R,
  GHOSTTY_KEY_S,
  GHOSTTY_KEY_T,
  GHOSTTY_KEY_U,
  GHOSTTY_KEY_V,
  GHOSTTY_KEY_W,
  GHOSTTY_KEY_X,
  GHOSTTY_KEY_Y,
  GHOSTTY_KEY_Z,
  GHOSTTY_KEY_MINUS,
  GHOSTTY_KEY_PERIOD,
  GHOSTTY_KEY_QUOTE,
  GHOSTTY_KEY_SEMICOLON,
  GHOSTTY_KEY_SLASH,

  // "Functional Keys" § 3.1.2
  GHOSTTY_KEY_ALT_LEFT,
  GHOSTTY_KEY_ALT_RIGHT,
  GHOSTTY_KEY_BACKSPACE,
  GHOSTTY_KEY_CAPS_LOCK,
  GHOSTTY_KEY_CONTEXT_MENU,
  GHOSTTY_KEY_CONTROL_LEFT,
  GHOSTTY_KEY_CONTROL_RIGHT,
  GHOSTTY_KEY_ENTER,
  GHOSTTY_KEY_META_LEFT,
  GHOSTTY_KEY_META_RIGHT,
  GHOSTTY_KEY_SHIFT_LEFT,
  GHOSTTY_KEY_SHIFT_RIGHT,
  GHOSTTY_KEY_SPACE,
  GHOSTTY_KEY_TAB,
  GHOSTTY_KEY_CONVERT,
  GHOSTTY_KEY_KANA_MODE,
  GHOSTTY_KEY_NON_CONVERT,

  // "Control Pad Section" § 3.2
  GHOSTTY_KEY_DELETE,
  GHOSTTY_KEY_END,
  GHOSTTY_KEY_HELP,
  GHOSTTY_KEY_HOME,
  GHOSTTY_KEY_INSERT,
  GHOSTTY_KEY_PAGE_DOWN,
  GHOSTTY_KEY_PAGE_UP,

  // "Arrow Pad Section" § 3.3
  GHOSTTY_KEY_ARROW_DOWN,
  GHOSTTY_KEY_ARROW_LEFT,
  GHOSTTY_KEY_ARROW_RIGHT,
  GHOSTTY_KEY_ARROW_UP,

  // "Numpad Section" § 3.4
  GHOSTTY_KEY_NUM_LOCK,
  GHOSTTY_KEY_NUMPAD_0,
  GHOSTTY_KEY_NUMPAD_1,
  GHOSTTY_KEY_NUMPAD_2,
  GHOSTTY_KEY_NUMPAD_3,
  GHOSTTY_KEY_NUMPAD_4,
  GHOSTTY_KEY_NUMPAD_5,
  GHOSTTY_KEY_NUMPAD_6,
  GHOSTTY_KEY_NUMPAD_7,
  GHOSTTY_KEY_NUMPAD_8,
  GHOSTTY_KEY_NUMPAD_9,
  GHOSTTY_KEY_NUMPAD_ADD,
  GHOSTTY_KEY_NUMPAD_BACKSPACE,
  GHOSTTY_KEY_NUMPAD_CLEAR,
  GHOSTTY_KEY_NUMPAD_CLEAR_ENTRY,
  GHOSTTY_KEY_NUMPAD_COMMA,
  GHOSTTY_KEY_NUMPAD_DECIMAL,
  GHOSTTY_KEY_NUMPAD_DIVIDE,
  GHOSTTY_KEY_NUMPAD_ENTER,
  GHOSTTY_KEY_NUMPAD_EQUAL,
  GHOSTTY_KEY_NUMPAD_MEMORY_ADD,
  GHOSTTY_KEY_NUMPAD_MEMORY_CLEAR,
  GHOSTTY_KEY_NUMPAD_MEMORY_RECALL,
  GHOSTTY_KEY_NUMPAD_MEMORY_STORE,
  GHOSTTY_KEY_NUMPAD_MEMORY_SUBTRACT,
  GHOSTTY_KEY_NUMPAD_MULTIPLY,
  GHOSTTY_KEY_NUMPAD_PAREN_LEFT,
  GHOSTTY_KEY_NUMPAD_PAREN_RIGHT,
  GHOSTTY_KEY_NUMPAD_SUBTRACT,
  GHOSTTY_KEY_NUMPAD_SEPARATOR,
  GHOSTTY_KEY_NUMPAD_UP,
  GHOSTTY_KEY_NUMPAD_DOWN,
  GHOSTTY_KEY_NUMPAD_RIGHT,
  GHOSTTY_KEY_NUMPAD_LEFT,
  GHOSTTY_KEY_NUMPAD_BEGIN,
  GHOSTTY_KEY_NUMPAD_HOME,
  GHOSTTY_KEY_NUMPAD_END,
  GHOSTTY_KEY_NUMPAD_INSERT,
  GHOSTTY_KEY_NUMPAD_DELETE,
  GHOSTTY_KEY_NUMPAD_PAGE_UP,
  GHOSTTY_KEY_NUMPAD_PAGE_DOWN,

  // "Function Section" § 3.5
  GHOSTTY_KEY_ESCAPE,
  GHOSTTY_KEY_F1,
  GHOSTTY_KEY_F2,
  GHOSTTY_KEY_F3,
  GHOSTTY_KEY_F4,
  GHOSTTY_KEY_F5,
  GHOSTTY_KEY_F6,
  GHOSTTY_KEY_F7,
  GHOSTTY_KEY_F8,
  GHOSTTY_KEY_F9,
  GHOSTTY_KEY_F10,
  GHOSTTY_KEY_F11,
  GHOSTTY_KEY_F12,
  GHOSTTY_KEY_F13,
  GHOSTTY_KEY_F14,
  GHOSTTY_KEY_F15,
  GHOSTTY_KEY_F16,
  GHOSTTY_KEY_F17,
  GHOSTTY_KEY_F18,
  GHOSTTY_KEY_F19,
  GHOSTTY_KEY_F20,
  GHOSTTY_KEY_F21,
  GHOSTTY_KEY_F22,
  GHOSTTY_KEY_F23,
  GHOSTTY_KEY_F24,
  GHOSTTY_KEY_F25,
  GHOSTTY_KEY_FN,
  GHOSTTY_KEY_FN_LOCK,
  GHOSTTY_KEY_PRINT_SCREEN,
  GHOSTTY_KEY_SCROLL_LOCK,
  GHOSTTY_KEY_PAUSE,

  // "Media Keys" § 3.6
  GHOSTTY_KEY_BROWSER_BACK,
  GHOSTTY_KEY_BROWSER_FAVORITES,
  GHOSTTY_KEY_BROWSER_FORWARD,
  GHOSTTY_KEY_BROWSER_HOME,
  GHOSTTY_KEY_BROWSER_REFRESH,
  GHOSTTY_KEY_BROWSER_SEARCH,
  GHOSTTY_KEY_BROWSER_STOP,
  GHOSTTY_KEY_EJECT,
  GHOSTTY_KEY_LAUNCH_APP_1,
  GHOSTTY_KEY_LAUNCH_APP_2,
  GHOSTTY_KEY_LAUNCH_MAIL,
  GHOSTTY_KEY_MEDIA_PLAY_PAUSE,
  GHOSTTY_KEY_MEDIA_SELECT,
  GHOSTTY_KEY_MEDIA_STOP,
  GHOSTTY_KEY_MEDIA_TRACK_NEXT,
  GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS,
  GHOSTTY_KEY_POWER,
  GHOSTTY_KEY_SLEEP,
  GHOSTTY_KEY_AUDIO_VOLUME_DOWN,
  GHOSTTY_KEY_AUDIO_VOLUME_MUTE,
  GHOSTTY_KEY_AUDIO_VOLUME_UP,
  GHOSTTY_KEY_WAKE_UP,

  // "Legacy, Non-standard, and Special Keys" § 3.7
  GHOSTTY_KEY_COPY,
  GHOSTTY_KEY_CUT,
  GHOSTTY_KEY_PASTE,
} ghostty_input_key_e;

typedef struct {
  ghostty_input_action_e action;
  ghostty_input_mods_e mods;
  ghostty_input_mods_e consumed_mods;
  // The platform's native keycode: a Mac virtual keycode on macOS, and on
  // iOS the USB HID keyboard usage that UIKit reports as UIKey.keyCode
  // (UIKeyboardHIDUsage, for example 0x04 for A).
  uint32_t keycode;
  const char* text;
  uint32_t unshifted_codepoint;
  bool composing;
} ghostty_input_key_s;

typedef enum {
  GHOSTTY_TRIGGER_PHYSICAL,
  GHOSTTY_TRIGGER_UNICODE,
  GHOSTTY_TRIGGER_CATCH_ALL,
} ghostty_input_trigger_tag_e;

typedef union {
  ghostty_input_key_e physical;
  uint32_t unicode;
  // catch_all has no payload
} ghostty_input_trigger_key_u;

typedef struct {
  ghostty_input_trigger_tag_e tag;
  ghostty_input_trigger_key_u key;
  ghostty_input_mods_e mods;
} ghostty_input_trigger_s;

typedef struct {
  const char* action_key;
  const char* action;
  const char* title;
  const char* description;
} ghostty_command_s;

typedef enum {
  GHOSTTY_BUILD_MODE_DEBUG,
  GHOSTTY_BUILD_MODE_RELEASE_SAFE,
  GHOSTTY_BUILD_MODE_RELEASE_FAST,
  GHOSTTY_BUILD_MODE_RELEASE_SMALL,
} ghostty_build_mode_e;

typedef struct {
  ghostty_build_mode_e build_mode;
  const char* version;
  uintptr_t version_len;
} ghostty_info_s;

typedef struct {
  const char* message;
} ghostty_diagnostic_s;

typedef struct {
  const char* ptr;
  uintptr_t len;
  bool sentinel;
} ghostty_string_s;

typedef struct {
  const char* path;
  uintptr_t line;
} ghostty_config_source_s;

typedef struct {
  double tl_px_x;
  double tl_px_y;
  uint32_t offset_start;
  uint32_t offset_len;
  const char* text;
  uintptr_t text_len;
} ghostty_text_s;

typedef enum {
  GHOSTTY_POINT_ACTIVE,
  GHOSTTY_POINT_VIEWPORT,
  GHOSTTY_POINT_SCREEN,
  GHOSTTY_POINT_SURFACE,
} ghostty_point_tag_e;

typedef enum {
  GHOSTTY_POINT_COORD_EXACT,
  GHOSTTY_POINT_COORD_TOP_LEFT,
  GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
} ghostty_point_coord_e;

typedef struct {
  ghostty_point_tag_e tag;
  ghostty_point_coord_e coord;
  uint32_t x;
  uint32_t y;
} ghostty_point_s;

typedef struct {
  ghostty_point_s top_left;
  ghostty_point_s bottom_right;
  bool rectangle;
} ghostty_selection_s;

typedef struct {
  const char* key;
  const char* value;
} ghostty_env_var_s;

typedef struct {
  void* nsview;
} ghostty_platform_macos_s;

typedef struct {
  void* uiview;
} ghostty_platform_ios_s;

typedef union {
  ghostty_platform_macos_s macos;
  ghostty_platform_ios_s ios;
} ghostty_platform_u;

typedef enum {
  GHOSTTY_SURFACE_CONTEXT_WINDOW = 0,
  GHOSTTY_SURFACE_CONTEXT_TAB = 1,
  GHOSTTY_SURFACE_CONTEXT_SPLIT = 2,
} ghostty_surface_context_e;

// Who owns the terminal byte stream of a surface.
//
// EXEC: Ghostty starts the command in a pty it owns (the default).
//
// MANUAL: the embedder owns the byte stream, for example a session host
// that owns the pty on another machine. Ghostty starts no subprocess,
// opens no pty and runs no read thread; command, working_directory and
// env_vars are ignored. Output arrives through
// ghostty_surface_process_output. Everything Ghostty would write to a
// pty goes to io_write_cb: encoded user input and the replies the parser
// generates (device attributes, status reports, ...). Kitty graphics
// load only in-band (t=d) data: file, temporary file and shared memory
// names in remote output do not name anything on this machine.
//
// MANUAL_MIRROR: like MANUAL, for a surface that mirrors the output of
// another terminal core that owns the terminal protocol. That core
// answers queries, so Ghostty drops every reply it would generate in
// answer to the output (DA, DSR, CPR, XTVERSION, DECRQM, DECRQSS,
// XTGETTCAP, Kitty keyboard and graphics replies, OSC 4/10/11/12 color
// replies, ENQ, CSI 21 t title reports, OSC 52 and OSC 5522 clipboard
// reads, OSC 5522 write status), and the size (mode 2048, CSI 14/16/18
// t), color scheme (mode 2031) and visibility (mode 2033) reports. Only
// user input reaches io_write_cb: keys, text, IME commits, paste
// (bracketed when the mirrored output enabled mode 2004), mouse reports
// (per the mirrored mouse modes) and focus reports (when the mirrored
// output enabled mode 1004). Clipboard writes (OSC 52 and OSC 5522)
// still reach the runtime's clipboard callbacks because they are not
// replies. The grid belongs to the owning core, so the clear_screen and
// reset binding actions do not change it and return false (not
// performed); the embedder asks the owner instead. The global `input`
// config is not sent; only an explicit initial_input is.
//
// In MANUAL mode the clear_screen action clears the local grid and, at a
// prompt, writes a form feed to io_write_cb in order with user input.
typedef enum {
  GHOSTTY_SURFACE_IO_EXEC = 0,
  GHOSTTY_SURFACE_IO_MANUAL = 1,
  GHOSTTY_SURFACE_IO_MANUAL_MIRROR = 2,
} ghostty_surface_io_mode_e;

// Receives bytes for the pty in the MANUAL and MANUAL_MIRROR modes:
// (io_write_userdata, bytes, length). The bytes are valid only during
// the call; copy them.
//
// Threading contract for a surface in a manual mode:
//
// - Call every surface function on the main (app) thread, including
//   ghostty_surface_set_size, except the output functions:
//   ghostty_surface_process_output, ghostty_surface_set_grid,
//   ghostty_surface_restore_snapshot and ghostty_surface_encode_snapshot.
// - Call the output functions from one serial queue that is not the
//   main thread, in the order of the owner's byte stream.
// - Never wait synchronously for that queue from the main thread or from
//   io_write_cb. Output parsing can wait for the main thread to drain
//   the app mailbox (ghostty_app_tick), so such a wait can deadlock.
// - Stop calling ghostty_surface_process_output, and let every call
//   return, before ghostty_surface_free.
//
// Blocking: no surface function waits for the renderer thread or for a
// GPU completion, except ghostty_surface_draw (a synchronous draw that
// waits for a free frame) and ghostty_surface_free (it joins the
// renderer thread). ghostty_surface_process_output, set_grid, set_size,
// set_content_scale, set_focus, set_occlusion, update_config and font
// size changes post their renderer work and return: when the renderer is
// behind, its mailbox grows instead of blocking, and a newer size, focus
// or visibility replaces an older pending one. The remaining waits are
// short lock holds and one queue:
// - The terminal lock. The renderer thread holds it while it copies the
//   terminal state for a frame (CPU work), and the output queue holds it
//   for one 64 KiB slice of output, one snapshot restore swap or history
//   page, or one snapshot encode. Main thread input and resize calls
//   take it. One exception reaches the GPU: when Kitty image placements
//   changed (or a snapshot was restored), the frame copy also takes the
//   draw lock, which a synchronous draw (ghostty_surface_draw, or the
//   layer's display pass on the main thread) holds while it waits for a
//   free frame.
// - The termio mailbox. Configuration changes and replies that a
//   manual surface does not handle on the caller's thread go to the
//   surface's IO thread, which never waits for the renderer.
// - The app mailbox. Output parsing that messages the app (title, bell,
//   clipboard, ...) waits while that mailbox is full, until the main
//   thread drains it in ghostty_app_tick (see the deadlock rule above).
//
// io_write_cb is called:
//
// - Synchronously, before the input call returns, on the thread that
//   called ghostty_surface_key, ghostty_surface_text,
//   ghostty_surface_text_input, ghostty_surface_mouse_*,
//   ghostty_surface_set_focus or ghostty_surface_binding_action
//   (clear_screen in MANUAL mode), and ghostty_surface_set_size for the
//   MANUAL mode 2048 size report. That is the main thread.
// - MANUAL mode only, on the main thread from ghostty_app_tick: replies
//   the surface sends for the parser (CSI 21 t title reports, OSC 52
//   clipboard reads, OSC 5522 clipboard replies and write status).
// - On the surface's IO thread: initial_input, and in MANUAL mode only,
//   the parser's direct replies (DA, DSR, ...) and the color scheme and
//   visibility reports.
//
// Calls for one surface never overlap. The callback may run while
// Ghostty holds the surface's terminal lock, so it must not call back
// into the surface. It can be called until ghostty_surface_free returns.
typedef void (*ghostty_io_write_cb)(void*, const char*, uintptr_t);

// Font binding actions reported after Ghostty applied them (increase,
// decrease, reset, set). The callback runs synchronously on the surface's
// GUI thread and must not free or reenter the surface.
typedef enum {
  GHOSTTY_FONT_SIZE_ACTION_INCREASE = 0,
  GHOSTTY_FONT_SIZE_ACTION_DECREASE = 1,
  GHOSTTY_FONT_SIZE_ACTION_RESET = 2,
  GHOSTTY_FONT_SIZE_ACTION_SET = 3,
} ghostty_font_size_action_e;
typedef void (*ghostty_font_size_action_cb)(
    void* userdata,
    ghostty_font_size_action_e action,
    float previous_points,
    float current_points,
    bool previous_adjusted,
    bool current_adjusted);

typedef struct {
  ghostty_platform_e platform_tag;
  ghostty_platform_u platform;
  void* userdata;
  double scale_factor;
  float font_size;
  const char* working_directory;
  const char* command;
  ghostty_env_var_s* env_vars;
  size_t env_var_count;
  const char* initial_input;
  bool wait_after_command;
  ghostty_surface_context_e context;
  // See ghostty_surface_io_mode_e. Surfaces that Ghostty asks the
  // embedder to create (new tab or split actions) do not inherit these
  // fields; they start in EXEC mode.
  ghostty_surface_io_mode_e io_mode;
  ghostty_io_write_cb io_write_cb;
  void* io_write_userdata;
} ghostty_surface_config_s;

typedef struct {
  uint16_t columns;
  uint16_t rows;
  uint32_t width_px;
  uint32_t height_px;
  uint32_t cell_width_px;
  uint32_t cell_height_px;
} ghostty_surface_size_s;

// Grid geometry in the embedder's logical (point) coordinates. The cursor
// fields name the canonical cursor cell (a wide glyph's lead) and are zero
// with cursor_in_viewport false when the cursor is scrolled out of view.
typedef struct {
  uint16_t columns;
  uint16_t rows;
  uint16_t cursor_column;
  uint16_t cursor_row;
  uint16_t cursor_width_cells;
  bool cursor_in_viewport;
  double cell_width;
  double cell_height;
  double padding_left;
  double padding_top;
} ghostty_surface_grid_metrics_s;

// The terminal grid of a surface, see ghostty_surface_grid.
typedef struct {
  // True after ghostty_surface_set_grid locked the grid.
  bool locked;
  uint16_t columns;
  uint16_t rows;
  // The generation of the last accepted ghostty_surface_set_grid, 0
  // while the grid is not locked.
  uint64_t generation;
} ghostty_surface_grid_s;

// Config types

// config.Path
typedef struct {
  const char* path;
  bool optional;
} ghostty_config_path_s;

// config.Color
typedef struct {
  uint8_t r;
  uint8_t g;
  uint8_t b;
} ghostty_config_color_s;

// config.WindowPadding.C (window-padding-x, window-padding-y), in points
typedef struct {
  uint32_t top_left;
  uint32_t bottom_right;
} ghostty_config_window_padding_s;

// config.ColorList
typedef struct {
  const ghostty_config_color_s* colors;
  size_t len;
} ghostty_config_color_list_s;

// config.RepeatableCommand
typedef struct {
  const ghostty_command_s* commands;
  size_t len;
} ghostty_config_command_list_s;

// config.Palette
typedef struct {
  ghostty_config_color_s colors[256];
} ghostty_config_palette_s;

// config.QuickTerminalSize
typedef enum {
  GHOSTTY_QUICK_TERMINAL_SIZE_NONE,
  GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE,
  GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS,
} ghostty_quick_terminal_size_tag_e;

typedef union {
  float percentage;
  uint32_t pixels;
} ghostty_quick_terminal_size_value_u;

typedef struct {
  ghostty_quick_terminal_size_tag_e tag;
  ghostty_quick_terminal_size_value_u value;
} ghostty_quick_terminal_size_s;

typedef struct {
  ghostty_quick_terminal_size_s primary;
  ghostty_quick_terminal_size_s secondary;
} ghostty_config_quick_terminal_size_s;

// config.Fullscreen
typedef enum {
  GHOSTTY_CONFIG_FULLSCREEN_FALSE,
  GHOSTTY_CONFIG_FULLSCREEN_TRUE,
  GHOSTTY_CONFIG_FULLSCREEN_NON_NATIVE,
  GHOSTTY_CONFIG_FULLSCREEN_NON_NATIVE_VISIBLE_MENU,
  GHOSTTY_CONFIG_FULLSCREEN_NON_NATIVE_PADDED_NOTCH,
} ghostty_config_fullscreen_e;

// apprt.Target.Key
typedef enum {
  GHOSTTY_TARGET_APP,
  GHOSTTY_TARGET_SURFACE,
} ghostty_target_tag_e;

typedef union {
  ghostty_surface_t surface;
} ghostty_target_u;

typedef struct {
  ghostty_target_tag_e tag;
  ghostty_target_u target;
} ghostty_target_s;

// apprt.action.SplitDirection
typedef enum {
  GHOSTTY_SPLIT_DIRECTION_RIGHT,
  GHOSTTY_SPLIT_DIRECTION_DOWN,
  GHOSTTY_SPLIT_DIRECTION_LEFT,
  GHOSTTY_SPLIT_DIRECTION_UP,
} ghostty_action_split_direction_e;

// apprt.action.GotoSplit
typedef enum {
  GHOSTTY_GOTO_SPLIT_PREVIOUS,
  GHOSTTY_GOTO_SPLIT_NEXT,
  GHOSTTY_GOTO_SPLIT_UP,
  GHOSTTY_GOTO_SPLIT_LEFT,
  GHOSTTY_GOTO_SPLIT_DOWN,
  GHOSTTY_GOTO_SPLIT_RIGHT,
} ghostty_action_goto_split_e;

// apprt.action.GotoWindow
typedef enum {
  GHOSTTY_GOTO_WINDOW_PREVIOUS,
  GHOSTTY_GOTO_WINDOW_NEXT,
} ghostty_action_goto_window_e;

// apprt.action.ResizeSplit.Direction
typedef enum {
  GHOSTTY_RESIZE_SPLIT_UP,
  GHOSTTY_RESIZE_SPLIT_DOWN,
  GHOSTTY_RESIZE_SPLIT_LEFT,
  GHOSTTY_RESIZE_SPLIT_RIGHT,
} ghostty_action_resize_split_direction_e;

// apprt.action.ResizeSplit
typedef struct {
  uint16_t amount;
  ghostty_action_resize_split_direction_e direction;
} ghostty_action_resize_split_s;

// apprt.action.MoveTab
typedef struct {
  ssize_t amount;
} ghostty_action_move_tab_s;

// apprt.action.GotoTab
typedef enum {
  GHOSTTY_GOTO_TAB_PREVIOUS = -1,
  GHOSTTY_GOTO_TAB_NEXT = -2,
  GHOSTTY_GOTO_TAB_LAST = -3,
} ghostty_action_goto_tab_e;

// apprt.action.Fullscreen
typedef enum {
  GHOSTTY_FULLSCREEN_NATIVE,
  GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE,
  GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE_VISIBLE_MENU,
  GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE_PADDED_NOTCH,
} ghostty_action_fullscreen_e;

// apprt.action.FloatWindow
typedef enum {
  GHOSTTY_FLOAT_WINDOW_ON,
  GHOSTTY_FLOAT_WINDOW_OFF,
  GHOSTTY_FLOAT_WINDOW_TOGGLE,
} ghostty_action_float_window_e;

// apprt.action.SecureInput
typedef enum {
  GHOSTTY_SECURE_INPUT_ON,
  GHOSTTY_SECURE_INPUT_OFF,
  GHOSTTY_SECURE_INPUT_TOGGLE,
} ghostty_action_secure_input_e;

// apprt.action.Inspector
typedef enum {
  GHOSTTY_INSPECTOR_TOGGLE,
  GHOSTTY_INSPECTOR_SHOW,
  GHOSTTY_INSPECTOR_HIDE,
} ghostty_action_inspector_e;

// apprt.action.ExportTerminalIO.C
typedef struct {
  const char* contents;
  size_t len;
} ghostty_action_export_terminal_io_s;

// apprt.action.QuitTimer
typedef enum {
  GHOSTTY_QUIT_TIMER_START,
  GHOSTTY_QUIT_TIMER_STOP,
} ghostty_action_quit_timer_e;

// apprt.action.Readonly
typedef enum {
  GHOSTTY_READONLY_OFF,
  GHOSTTY_READONLY_ON,
} ghostty_action_readonly_e;

// apprt.action.DesktopNotification.C
typedef struct {
  const char* title;
  const char* body;
} ghostty_action_desktop_notification_s;

// apprt.action.SetTitle.C
typedef struct {
  const char* title;
} ghostty_action_set_title_s;

// apprt.action.PromptTitle
typedef enum {
  GHOSTTY_PROMPT_TITLE_SURFACE,
  GHOSTTY_PROMPT_TITLE_TAB,
  GHOSTTY_PROMPT_TITLE_WINDOW,
} ghostty_action_prompt_title_e;

// apprt.action.Pwd.C
typedef struct {
  const char* pwd;
} ghostty_action_pwd_s;

// apprt.action.OpenConfig
typedef enum {
  // Open the config in the OS default editor.
  GHOSTTY_ACTION_OPEN_CONFIG_OS_OPEN,
  // Open the config in a new window using $EDITOR or $VISUAL
  GHOSTTY_ACTION_OPEN_CONFIG_NEW_WINDOW,
} ghostty_action_open_config_e;

// terminal.MouseShape
typedef enum {
  GHOSTTY_MOUSE_SHAPE_DEFAULT,
  GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU,
  GHOSTTY_MOUSE_SHAPE_HELP,
  GHOSTTY_MOUSE_SHAPE_POINTER,
  GHOSTTY_MOUSE_SHAPE_PROGRESS,
  GHOSTTY_MOUSE_SHAPE_WAIT,
  GHOSTTY_MOUSE_SHAPE_CELL,
  GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
  GHOSTTY_MOUSE_SHAPE_TEXT,
  GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT,
  GHOSTTY_MOUSE_SHAPE_ALIAS,
  GHOSTTY_MOUSE_SHAPE_COPY,
  GHOSTTY_MOUSE_SHAPE_MOVE,
  GHOSTTY_MOUSE_SHAPE_NO_DROP,
  GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
  GHOSTTY_MOUSE_SHAPE_GRAB,
  GHOSTTY_MOUSE_SHAPE_GRABBING,
  GHOSTTY_MOUSE_SHAPE_ALL_SCROLL,
  GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
  GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_N_RESIZE,
  GHOSTTY_MOUSE_SHAPE_E_RESIZE,
  GHOSTTY_MOUSE_SHAPE_S_RESIZE,
  GHOSTTY_MOUSE_SHAPE_W_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NE_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_SE_RESIZE,
  GHOSTTY_MOUSE_SHAPE_SW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NESW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE,
  GHOSTTY_MOUSE_SHAPE_ZOOM_IN,
  GHOSTTY_MOUSE_SHAPE_ZOOM_OUT,
} ghostty_action_mouse_shape_e;

// apprt.action.MouseVisibility
typedef enum {
  GHOSTTY_MOUSE_VISIBLE,
  GHOSTTY_MOUSE_HIDDEN,
} ghostty_action_mouse_visibility_e;

// apprt.action.MouseOverLink
typedef struct {
  const char* url;
  size_t len;
} ghostty_action_mouse_over_link_s;

// apprt.action.SizeLimit
typedef struct {
  uint32_t min_width;
  uint32_t min_height;
  uint32_t max_width;
  uint32_t max_height;
} ghostty_action_size_limit_s;

// apprt.action.InitialSize
typedef struct {
  uint32_t width;
  uint32_t height;
} ghostty_action_initial_size_s;

// apprt.action.ResizeWindow
typedef struct {
  uint32_t width;
  uint32_t height;
} ghostty_action_resize_window_s;

// apprt.action.CellSize
typedef struct {
  uint32_t width;
  uint32_t height;
} ghostty_action_cell_size_s;

// renderer.Health
typedef enum {
  GHOSTTY_RENDERER_HEALTH_HEALTHY,
  GHOSTTY_RENDERER_HEALTH_UNHEALTHY,
} ghostty_action_renderer_health_e;

// apprt.action.KeySequence
typedef struct {
  bool active;
  ghostty_input_trigger_s trigger;
} ghostty_action_key_sequence_s;

// apprt.action.KeyTable.Tag
typedef enum {
  GHOSTTY_KEY_TABLE_ACTIVATE,
  GHOSTTY_KEY_TABLE_DEACTIVATE,
  GHOSTTY_KEY_TABLE_DEACTIVATE_ALL,
} ghostty_action_key_table_tag_e;

// apprt.action.KeyTable.CValue
typedef union {
  struct {
    const char *name;
    size_t len;
  } activate;
} ghostty_action_key_table_u;

// apprt.action.KeyTable.C
typedef struct {
  ghostty_action_key_table_tag_e tag;
  ghostty_action_key_table_u value;
} ghostty_action_key_table_s;

// apprt.action.ColorKind
typedef enum {
  GHOSTTY_ACTION_COLOR_KIND_FOREGROUND = -1,
  GHOSTTY_ACTION_COLOR_KIND_BACKGROUND = -2,
  GHOSTTY_ACTION_COLOR_KIND_CURSOR = -3,
} ghostty_action_color_kind_e;

// apprt.action.ColorChange
typedef struct {
  ghostty_action_color_kind_e kind;
  uint8_t r;
  uint8_t g;
  uint8_t b;
} ghostty_action_color_change_s;

// apprt.action.ConfigChange
typedef struct {
  ghostty_config_t config;
} ghostty_action_config_change_s;

// apprt.action.ReloadConfig
typedef struct {
  bool soft;
} ghostty_action_reload_config_s;

// apprt.action.OpenUrlKind
typedef enum {
  GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
  GHOSTTY_ACTION_OPEN_URL_KIND_TEXT,
  GHOSTTY_ACTION_OPEN_URL_KIND_HTML,
  GHOSTTY_ACTION_OPEN_URL_KIND_OSC8,
} ghostty_action_open_url_kind_e;

// apprt.action.OpenUrl.C
typedef struct {
  ghostty_action_open_url_kind_e kind;
  const char* url;
  uintptr_t len;
} ghostty_action_open_url_s;

// apprt.action.CloseTabMode
typedef enum {
  GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS,
  GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER,
  GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT,
} ghostty_action_close_tab_mode_e;

// apprt.surface.Message.ChildExited
typedef struct {
  uint32_t exit_code;
  uint64_t timetime_ms;
} ghostty_surface_message_childexited_s;

// terminal.osc.Command.ProgressReport.State
typedef enum {
  GHOSTTY_PROGRESS_STATE_REMOVE,
  GHOSTTY_PROGRESS_STATE_SET,
  GHOSTTY_PROGRESS_STATE_ERROR,
  GHOSTTY_PROGRESS_STATE_INDETERMINATE,
  GHOSTTY_PROGRESS_STATE_PAUSE,
} ghostty_action_progress_report_state_e;

// terminal.osc.Command.ProgressReport.C
typedef struct {
  ghostty_action_progress_report_state_e state;
  // -1 if no progress was reported, otherwise 0-100 indicating percent
  // completeness.
  int8_t progress;
} ghostty_action_progress_report_s;

// apprt.action.CommandFinished.C
typedef struct {
  // -1 if no exit code was reported, otherwise 0-255
  int16_t exit_code;
  // number of nanoseconds that command was running for
  uint64_t duration;
} ghostty_action_command_finished_s;

// apprt.action.StartSearch.C
typedef struct {
  const char* needle;
} ghostty_action_start_search_s;

// apprt.action.SearchTotal
typedef struct {
  ssize_t total;
} ghostty_action_search_total_s;

// apprt.action.SearchSelected
typedef struct {
  ssize_t selected;
} ghostty_action_search_selected_s;

// terminal.Scrollbar
typedef struct {
  uint64_t total;
  uint64_t offset;
  uint64_t len;
} ghostty_action_scrollbar_s;

// apprt.Action.Key
typedef enum {
  GHOSTTY_ACTION_QUIT,
  GHOSTTY_ACTION_NEW_WINDOW,
  GHOSTTY_ACTION_NEW_TAB,
  GHOSTTY_ACTION_CLOSE_TAB,
  GHOSTTY_ACTION_NEW_SPLIT,
  GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,
  GHOSTTY_ACTION_TOGGLE_MAXIMIZE,
  GHOSTTY_ACTION_TOGGLE_FULLSCREEN,
  GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW,
  GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS,
  GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
  GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE,
  GHOSTTY_ACTION_TOGGLE_VISIBILITY,
  GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY,
  GHOSTTY_ACTION_MOVE_TAB,
  GHOSTTY_ACTION_GOTO_TAB,
  GHOSTTY_ACTION_GOTO_SPLIT,
  GHOSTTY_ACTION_GOTO_WINDOW,
  GHOSTTY_ACTION_RESIZE_SPLIT,
  GHOSTTY_ACTION_EQUALIZE_SPLITS,
  GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM,
  GHOSTTY_ACTION_PRESENT_TERMINAL,
  GHOSTTY_ACTION_SIZE_LIMIT,
  GHOSTTY_ACTION_RESET_WINDOW_SIZE,
  GHOSTTY_ACTION_INITIAL_SIZE,
  GHOSTTY_ACTION_CELL_SIZE,
  GHOSTTY_ACTION_SCROLLBAR,
  GHOSTTY_ACTION_RENDER,
  GHOSTTY_ACTION_INSPECTOR,
  GHOSTTY_ACTION_SHOW_GTK_INSPECTOR,
  GHOSTTY_ACTION_RENDER_INSPECTOR,
  GHOSTTY_ACTION_EXPORT_TERMINAL_IO,
  GHOSTTY_ACTION_DESKTOP_NOTIFICATION,
  GHOSTTY_ACTION_SET_TITLE,
  GHOSTTY_ACTION_SET_TAB_TITLE,
  GHOSTTY_ACTION_SET_WINDOW_TITLE,
  GHOSTTY_ACTION_PROMPT_TITLE,
  GHOSTTY_ACTION_PWD,
  GHOSTTY_ACTION_MOUSE_SHAPE,
  GHOSTTY_ACTION_MOUSE_VISIBILITY,
  GHOSTTY_ACTION_MOUSE_OVER_LINK,
  GHOSTTY_ACTION_RENDERER_HEALTH,
  GHOSTTY_ACTION_OPEN_CONFIG,
  GHOSTTY_ACTION_QUIT_TIMER,
  GHOSTTY_ACTION_FLOAT_WINDOW,
  GHOSTTY_ACTION_SECURE_INPUT,
  GHOSTTY_ACTION_KEY_SEQUENCE,
  GHOSTTY_ACTION_KEY_TABLE,
  GHOSTTY_ACTION_COLOR_CHANGE,
  GHOSTTY_ACTION_RELOAD_CONFIG,
  GHOSTTY_ACTION_CONFIG_CHANGE,
  GHOSTTY_ACTION_CLOSE_WINDOW,
  GHOSTTY_ACTION_RING_BELL,
  GHOSTTY_ACTION_SELECTION_CHANGED,
  GHOSTTY_ACTION_UNDO,
  GHOSTTY_ACTION_REDO,
  GHOSTTY_ACTION_CHECK_FOR_UPDATES,
  GHOSTTY_ACTION_OPEN_URL,
  GHOSTTY_ACTION_SHOW_CHILD_EXITED,
  GHOSTTY_ACTION_PROGRESS_REPORT,
  GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD,
  GHOSTTY_ACTION_COMMAND_FINISHED,
  GHOSTTY_ACTION_START_SEARCH,
  GHOSTTY_ACTION_END_SEARCH,
  GHOSTTY_ACTION_SEARCH_TOTAL,
  GHOSTTY_ACTION_SEARCH_SELECTED,
  GHOSTTY_ACTION_READONLY,
  GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD,
  GHOSTTY_ACTION_MOVE_TAB_TO_NEW_WINDOW,
  GHOSTTY_ACTION_RESIZE_WINDOW,
} ghostty_action_tag_e;

typedef union {
  ghostty_action_split_direction_e new_split;
  ghostty_action_fullscreen_e toggle_fullscreen;
  ghostty_action_move_tab_s move_tab;
  ghostty_action_goto_tab_e goto_tab;
  ghostty_action_goto_split_e goto_split;
  ghostty_action_goto_window_e goto_window;
  ghostty_action_resize_split_s resize_split;
  ghostty_action_size_limit_s size_limit;
  ghostty_action_initial_size_s initial_size;
  ghostty_action_resize_window_s resize_window;
  ghostty_action_cell_size_s cell_size;
  ghostty_action_scrollbar_s scrollbar;
  ghostty_action_inspector_e inspector;
  ghostty_action_export_terminal_io_s export_terminal_io;
  ghostty_action_desktop_notification_s desktop_notification;
  ghostty_action_set_title_s set_title;
  ghostty_action_set_title_s set_tab_title;
  ghostty_action_prompt_title_e prompt_title;
  ghostty_action_pwd_s pwd;
  ghostty_action_mouse_shape_e mouse_shape;
  ghostty_action_mouse_visibility_e mouse_visibility;
  ghostty_action_mouse_over_link_s mouse_over_link;
  ghostty_action_renderer_health_e renderer_health;
  ghostty_action_quit_timer_e quit_timer;
  ghostty_action_float_window_e float_window;
  ghostty_action_secure_input_e secure_input;
  ghostty_action_key_sequence_s key_sequence;
  ghostty_action_key_table_s key_table;
  ghostty_action_color_change_s color_change;
  ghostty_action_reload_config_s reload_config;
  ghostty_action_config_change_s config_change;
  ghostty_action_open_url_s open_url;
  ghostty_action_close_tab_mode_e close_tab_mode;
  ghostty_surface_message_childexited_s child_exited;
  ghostty_action_progress_report_s progress_report;
  ghostty_action_command_finished_s command_finished;
  ghostty_action_start_search_s start_search;
  ghostty_action_search_total_s search_total;
  ghostty_action_search_selected_s search_selected;
  ghostty_action_readonly_e readonly;
  ghostty_action_open_config_e open_config;
} ghostty_action_u;

typedef struct {
  ghostty_action_tag_e tag;
  ghostty_action_u action;
} ghostty_action_s;

typedef void (*ghostty_runtime_wakeup_cb)(void*);
typedef ghostty_clipboard_read_result_e (*ghostty_runtime_read_clipboard_cb)(
    void*,
    ghostty_clipboard_e,
    void*,
    const char* const*,
    size_t,
    bool);
typedef void (*ghostty_runtime_confirm_read_clipboard_cb)(
    void*,
    const ghostty_clipboard_confirm_s*,
    void*,
    ghostty_clipboard_request_e);
typedef void (*ghostty_runtime_write_clipboard_cb)(void*,
                                                   ghostty_clipboard_e,
                                                   const ghostty_clipboard_content_s*,
                                                   size_t,
                                                   bool);
typedef void (*ghostty_runtime_close_surface_cb)(void*, bool);
typedef bool (*ghostty_runtime_action_cb)(ghostty_app_t,
                                          ghostty_target_s,
                                          ghostty_action_s);

typedef struct {
  void* userdata;
  bool supports_selection_clipboard;
  ghostty_runtime_wakeup_cb wakeup_cb;
  ghostty_runtime_action_cb action_cb;
  ghostty_runtime_read_clipboard_cb read_clipboard_cb;
  ghostty_runtime_confirm_read_clipboard_cb confirm_read_clipboard_cb;
  ghostty_runtime_write_clipboard_cb write_clipboard_cb;
  ghostty_runtime_close_surface_cb close_surface_cb;
} ghostty_runtime_config_s;

// apprt.ipc.Target.Key
typedef enum {
  GHOSTTY_IPC_TARGET_CLASS,
  GHOSTTY_IPC_TARGET_DETECT,
} ghostty_ipc_target_tag_e;

typedef union {
  char *klass;
} ghostty_ipc_target_u;

typedef struct {
  ghostty_ipc_target_tag_e tag;
  ghostty_ipc_target_u target;
} chostty_ipc_target_s;

// apprt.ipc.Action.NewWindow
typedef struct {
  // This should be a null terminated list of strings.
  const char **arguments;
} ghostty_ipc_action_new_window_s;

typedef union {
  ghostty_ipc_action_new_window_s new_window;
} ghostty_ipc_action_u;

// apprt.ipc.Action.Key
typedef enum {
  GHOSTTY_IPC_ACTION_NEW_WINDOW,
  GHOSTTY_IPC_ACTION_NEW_TAB,
  GHOSTTY_IPC_ACTION_TOGGLE_QUICK_TERMINAL,
} ghostty_ipc_action_tag_e;

//-------------------------------------------------------------------
// Published API

GHOSTTY_API int ghostty_init(uintptr_t, char**);
GHOSTTY_API void ghostty_cli_try_action(void);
GHOSTTY_API ghostty_info_s ghostty_info(void);
GHOSTTY_API const char* ghostty_translate(const char*);
GHOSTTY_API void ghostty_string_free(ghostty_string_s);

GHOSTTY_API ghostty_config_t ghostty_config_new();
GHOSTTY_API void ghostty_config_free(ghostty_config_t);
GHOSTTY_API ghostty_config_t ghostty_config_clone(ghostty_config_t);
GHOSTTY_API void ghostty_config_load_cli_args(ghostty_config_t);
GHOSTTY_API void ghostty_config_load_file(ghostty_config_t, const char*);
GHOSTTY_API void ghostty_config_load_string(ghostty_config_t, const char*, uintptr_t, const char*);
GHOSTTY_API void ghostty_config_load_default_files(ghostty_config_t);
GHOSTTY_API void ghostty_config_load_recursive_files(ghostty_config_t);
GHOSTTY_API void ghostty_config_finalize(ghostty_config_t);
GHOSTTY_API bool ghostty_config_get(ghostty_config_t, void*, const char*, uintptr_t);
GHOSTTY_API ghostty_input_trigger_s ghostty_config_trigger(ghostty_config_t,
                                                              const char*,
                                                              uintptr_t);
GHOSTTY_API bool ghostty_config_key_is_binding(ghostty_config_t, ghostty_input_key_s);
GHOSTTY_API uint32_t ghostty_config_diagnostics_count(ghostty_config_t);
GHOSTTY_API ghostty_diagnostic_s ghostty_config_get_diagnostic(ghostty_config_t, uint32_t);
GHOSTTY_API ghostty_string_s ghostty_config_open_path(void);
// Config introspection (ghostty-next). Keys: `ghostty_config_key_name`
// returns a static NUL-terminated name for 0 ..< key_count, NULL past it.
// Sources: the file and 1-based line of a key's last assignment; false when
// the key is at its default, came from the command line, or is unknown. The
// path and the loaded-file strings are owned by the config.
GHOSTTY_API uintptr_t ghostty_config_key_count(void);
GHOSTTY_API const char* ghostty_config_key_name(uintptr_t);
GHOSTTY_API bool ghostty_config_key_source(ghostty_config_t,
                                           const char*,
                                           uintptr_t,
                                           ghostty_config_source_s*);
GHOSTTY_API uintptr_t ghostty_config_loaded_file_count(ghostty_config_t);
GHOSTTY_API const char* ghostty_config_loaded_file(ghostty_config_t, uintptr_t);

GHOSTTY_API ghostty_app_t ghostty_app_new(const ghostty_runtime_config_s*,
                                             ghostty_config_t);
GHOSTTY_API void ghostty_app_free(ghostty_app_t);
GHOSTTY_API void ghostty_app_tick(ghostty_app_t);
GHOSTTY_API void* ghostty_app_userdata(ghostty_app_t);
GHOSTTY_API void ghostty_app_set_focus(ghostty_app_t, bool);
GHOSTTY_API bool ghostty_app_key(ghostty_app_t, ghostty_input_key_s);
GHOSTTY_API void ghostty_app_keyboard_changed(ghostty_app_t);
GHOSTTY_API void ghostty_app_open_config(ghostty_app_t);
GHOSTTY_API void ghostty_app_update_config(ghostty_app_t, ghostty_config_t);
GHOSTTY_API bool ghostty_app_needs_confirm_quit(ghostty_app_t);
GHOSTTY_API bool ghostty_app_has_global_keybinds(ghostty_app_t);
GHOSTTY_API void ghostty_app_set_color_scheme(ghostty_app_t, ghostty_color_scheme_e);

GHOSTTY_API ghostty_surface_config_s ghostty_surface_config_new();

GHOSTTY_API ghostty_surface_t ghostty_surface_new(ghostty_app_t,
                                                     const ghostty_surface_config_s*);
GHOSTTY_API void ghostty_surface_free(ghostty_surface_t);
GHOSTTY_API void* ghostty_surface_userdata(ghostty_surface_t);
GHOSTTY_API ghostty_app_t ghostty_surface_app(ghostty_surface_t);
GHOSTTY_API ghostty_surface_config_s ghostty_surface_inherited_config(ghostty_surface_t, ghostty_surface_context_e);
GHOSTTY_API void ghostty_surface_update_config(ghostty_surface_t, ghostty_config_t);
GHOSTTY_API bool ghostty_surface_needs_confirm_quit(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_process_exited(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_refresh(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_draw(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_set_content_scale(ghostty_surface_t, double, double);
GHOSTTY_API void ghostty_surface_set_focus(ghostty_surface_t, bool);
GHOSTTY_API void ghostty_surface_set_occlusion(ghostty_surface_t, bool);
// Install a per-surface callback for performed font binding actions. Call
// once after ghostty_surface_new; a second call returns false. Not inherited
// by child surfaces. userdata must stay valid until ghostty_surface_free
// returns.
GHOSTTY_API bool ghostty_surface_set_font_size_action_callback(
    ghostty_surface_t,
    ghostty_font_size_action_cb,
    void* userdata);
GHOSTTY_API void ghostty_surface_set_size(ghostty_surface_t, uint32_t, uint32_t);
GHOSTTY_API ghostty_surface_size_s ghostty_surface_size(ghostty_surface_t);
// Fills the grid metrics. Returns false while a resize of an unlocked grid
// is in flight; with a host-locked grid (ghostty_surface_set_grid) the
// metrics describe the locked grid. Takes the terminal lock briefly.
GHOSTTY_API bool ghostty_surface_grid_metrics(ghostty_surface_t,
                                              ghostty_surface_grid_metrics_s*);
// Lock the terminal grid of a MANUAL or MANUAL_MIRROR surface to
// cols x rows, the grid of the terminal core that owns the byte stream,
// independent of the view's pixel size. Call it from the output queue
// (see ghostty_io_write_cb), in order with ghostty_surface_process_output.
//
// After the lock, ghostty_surface_set_size and font size changes set
// only the pixel size; ghostty_surface_size still reports how many cells
// would fit the view (the embedder's viewport proposal to the owner).
// The grid is drawn from the top-left corner of the view, after the
// configured window padding. In a larger view the rest is padding in
// the background color. In a smaller view the grid is cropped: the
// columns and rows beyond the right and bottom edges are not drawn.
//
// A MANUAL_MIRROR surface never reflows on its own: a grid change, and
// any resize, clips or pads the lines, and the owner follows its own
// reflow with a snapshot (ghostty_surface_restore_snapshot). A MANUAL
// surface reflows like any resize and sends the mode 2048 size report
// when the output enabled it.
//
// generation is the owner's grid generation. A call with a generation
// older than the current lock is refused. Returns false, and changes
// nothing, for an EXEC surface, a zero dimension, an older generation or
// a failed allocation.
GHOSTTY_API bool ghostty_surface_set_grid(ghostty_surface_t,
                                          uint16_t cols,
                                          uint16_t rows,
                                          uint64_t generation);
// The terminal's current grid and its lock. Any thread may call it,
// except from io_write_cb (it takes the terminal lock).
GHOSTTY_API ghostty_surface_grid_s ghostty_surface_grid(ghostty_surface_t);
GHOSTTY_API uint64_t ghostty_surface_foreground_pid(ghostty_surface_t);
GHOSTTY_API ghostty_string_s ghostty_surface_tty_name(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_set_color_scheme(ghostty_surface_t,
                                                     ghostty_color_scheme_e);
GHOSTTY_API ghostty_input_mods_e ghostty_surface_key_translation_mods(ghostty_surface_t,
                                                                         ghostty_input_mods_e);
GHOSTTY_API bool ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s);
GHOSTTY_API bool ghostty_surface_key_is_binding(ghostty_surface_t,
                                                   ghostty_input_key_s,
                                                   ghostty_binding_flags_e*);
GHOSTTY_API void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);
// Send committed text, such as typed text or an IME commit, as if typed.
// Unlike ghostty_surface_text (a paste), there is no bracketed paste and
// no paste protection, and LF becomes CR like the Enter key.
GHOSTTY_API void ghostty_surface_text_input(ghostty_surface_t,
                                            const char*,
                                            uintptr_t);
GHOSTTY_API void ghostty_surface_preedit(ghostty_surface_t, const char*, uintptr_t);
// Parse terminal output as if it was read from the pty and render it.
// This is how a MANUAL or MANUAL_MIRROR surface receives output; for an
// EXEC surface it does nothing. See ghostty_io_write_cb for the thread
// rules. The bytes are parsed in 64 KiB slices, each under one hold of
// the surface's terminal lock, so a call blocks while the renderer or
// the main thread holds that lock.
//
// Until ghostty_surface_set_grid locks the grid,
// ghostty_surface_set_size (and a font size change) in the MANUAL modes
// resizes the local grid before it returns. It takes the terminal lock,
// so the resize lands between two slices of output. The resize does what
// the terminal does for any resize: in MANUAL mode the primary screen
// reflows soft-wrapped lines when wraparound (DECAWM) is on (a
// MANUAL_MIRROR surface never reflows), the alternate screen is clipped
// or padded without reflow, and synchronized output (mode 2026) ends. No pty is resized and nothing is written, except the
// mode 2048 size report in MANUAL mode. The terminal core that owns the
// pty resizes and reflows its own grid. Both grids stay identical only
// when the local resize lands at the same point in the byte stream as
// the owner's: stop feeding output at that point, let the output queue
// drain (wait asynchronously, never block the main thread on it), call
// ghostty_surface_set_size on the main thread, then resume feeding.
// Otherwise resync the mirror from the owner.
GHOSTTY_API void ghostty_surface_process_output(ghostty_surface_t,
                                                const char*,
                                                uintptr_t);
GHOSTTY_API bool ghostty_surface_mouse_captured(ghostty_surface_t);

// Which part of a GHOSTSNP terminal snapshot (the libghostty-vt snapshot
// format, see ghostty/vt/snapshot.h) a surface restores or encodes.
//
// READY: the renderable prefix, from the envelope through the READY
// marker: terminal state, both screens, and the unfinished escape
// sequence at the cut (the continuation).
// HISTORY: the records after READY: scrollback pages, through FINISH.
// COMPLETE: READY followed by HISTORY, one complete snapshot.
typedef enum {
  GHOSTTY_SURFACE_SNAPSHOT_READY = 0,
  GHOSTTY_SURFACE_SNAPSHOT_HISTORY = 1,
  GHOSTTY_SURFACE_SNAPSHOT_COMPLETE = 2,
} ghostty_surface_snapshot_phase_e;

// Receives an encoded snapshot: (userdata, bytes, length). The bytes are
// valid only during the call; copy them.
typedef void (*ghostty_surface_snapshot_write_cb)(void*,
                                                  const uint8_t*,
                                                  size_t);

// Replace the terminal state of a MANUAL or MANUAL_MIRROR surface from a
// snapshot that the terminal core owning the byte stream encoded. Call
// it from the output queue (see ghostty_io_write_cb), in order with
// ghostty_surface_process_output: output that follows the snapshot cut
// is fed after it.
//
// READY (or COMPLETE): bytes start at the snapshot envelope and hold at
// least the READY prefix. The prefix is decoded without the terminal
// lock, then swapped in atomically: the renderer draws the old terminal
// or the new one, never a mix. History bytes after READY in the same
// buffer are applied as with HISTORY. A READY restore abandons the
// history of an earlier snapshot that is still arriving.
//
// HISTORY: bytes continue the same snapshot after READY and may be cut
// anywhere. Complete scrollback pages are prepended above the restored
// screens (newest first, as the snapshot orders them); an incomplete
// record waits for the next call; FINISH ends the snapshot. Pages are
// dropped, not applied, when output since READY changed the width or
// replaced the screen.
//
// The restore emits nothing to io_write_cb. The restored terminal takes
// the snapshot's grid, modes (except mode 12, cursor blinking, while the
// cursor follows its default: it takes the local cursor-style-blink) and
// the program's color overrides; a grid
// locked with ghostty_surface_set_grid takes the snapshot's size and
// keeps its generation. The surface's own config replaces the owner's
// local policy: the scrollback limits (scrollback-limit-bytes,
// scrollback-limit-lines), so HISTORY pages beyond them are dropped from
// the oldest end, the Kitty image storage limit, in-band only image
// loading, the default palette (OSC 4 overrides stay), the default
// background, foreground and cursor colors (OSC 10/11/12 overrides
// stay), and the default cursor style and blink (cursor-style,
// cursor-style-blink; a program's explicit DECSCUSR stays). In the
// MANUAL modes, ghostty_surface_update_config applies new scrollback
// limits to the live terminal too: the oldest complete history pages
// are freed, never the screen or the Kitty images on it. Snapshot format version 1 carries no Kitty
// images: a READY restore leaves no images. The owner then sends the
// stream of ghostty_terminal_kitty_replay_encode (libghostty-vt), which
// the caller applies with ghostty_surface_apply_kitty_replay after the
// restore (after HISTORY for placements above the screen). Never pass
// that stream to ghostty_surface_process_output.
//
// A restored synchronized update (mode 2026) gets the same safety
// timeout as one the output starts.
//
// Returns false for an EXEC surface, an unknown phase, a malformed or
// unsupported snapshot, a record longer than 64 MiB, or HISTORY with no
// snapshot in progress. A failed READY leaves the terminal unchanged (it
// still abandons the history of an earlier snapshot); a failed HISTORY
// keeps the pages applied so far and ends the restore.
GHOSTTY_API bool ghostty_surface_restore_snapshot(
    ghostty_surface_t,
    const uint8_t*,
    size_t,
    ghostty_surface_snapshot_phase_e);

// Results of ghostty_surface_restore_snapshot_local_history.
typedef enum {
  GHOSTTY_SURFACE_LOCAL_HISTORY_ERROR = -1,
  GHOSTTY_SURFACE_LOCAL_HISTORY_RESTORED = 0,
  GHOSTTY_SURFACE_LOCAL_HISTORY_MISMATCH = 1,
} ghostty_surface_local_history_result_e;

// The length and algorithm version of a history digest
// (ghostty_terminal_history_digest in ghostty/vt/terminal.h; equal to
// GHOSTTY_TERMINAL_HISTORY_DIGEST_LEN and _VERSION).
#define GHOSTTY_SURFACE_HISTORY_DIGEST_LEN 32
#define GHOSTTY_SURFACE_HISTORY_DIGEST_VERSION 2

// Restore a READY snapshot prefix into a MANUAL_MIRROR (or MANUAL)
// surface and keep this surface's own scrollback, reflowed, instead of
// receiving the history from the owner. Use it after an owner resize so
// the owner does not resend all history.
//
// Caller contract. The owner resizes its terminal (Terminal.resize, reflow
// on), then, under its terminal lock and before it parses more output,
// encodes the READY prefix and calls ghostty_terminal_history_digest on
// the same terminal (expected_history_rows, expected_digest; nothing may
// change the terminal between the two, because the digest window is
// placed by the page layout that READY encodes). Both sides keep
// resize_pull_scrollback at its default (true): GHOSTSNP v1 does not
// carry it. The mirror calls this function from the output queue (see
// ghostty_io_write_cb) exactly at that point in the byte stream: it has
// parsed the same bytes as the owner up to the resize, at the OLD grid,
// its terminal started from a COMPLETE snapshot of the owner (so its
// parsing modes, such as grapheme clustering, are the owner's), and it
// has not called ghostty_surface_set_grid for the new size (that clips or
// pads a mirror). On any doubt (a cut that is not a resize, a lost frame,
// a restart, different config) send READY + HISTORY with
// ghostty_surface_restore_snapshot instead.
//
// bytes hold exactly the READY prefix: from the snapshot envelope through
// the READY marker. Bytes after READY are an error (history records go to
// ghostty_surface_restore_snapshot). digest_len must be
// GHOSTTY_SURFACE_HISTORY_DIGEST_LEN.
//
// The READY's first primary page holds the owner's newest S history rows
// (the seam). The surface swaps in the READY terminal under the terminal
// lock (the old terminal is then private to the call), then, without the
// lock, resizes its old terminal to the
// snapshot's grid with Terminal.resize, using the READY's prompt redraw
// and wraparound (the primary screen reflows soft-wrapped lines when
// wraparound is on; this surface's scrollback limits apply as in any
// resize), and computes the digest of the result at the seam S (H_local
// rows). It is a match when the digest equals expected_digest and either
// H_local == expected_history_rows, or H_local < expected_history_rows,
// both have at least 64 rows above the seam, and this surface's
// scrollback limit cut its primary history: it dropped the oldest rows
// and the history is within one page of the line or byte limit before or
// after the reflow (a mirror with a smaller limit than the owner; a wider
// resize or short lines can leave a cut history far below the limit). Anything else is a
// mismatch. The digest covers the 64 rows above the seam; older rows are
// checked by the row count only, and not at all when the local limit cut
// the history. With a cut oldest part the oldest kept logical line can be
// a fragment whose reflowed rows differ from the owner's; every newer row
// is the owner's.
//
// Returns GHOSTTY_SURFACE_LOCAL_HISTORY_RESTORED (0) on a match: without
// the lock, the old terminal's reflowed primary history older than the
// seam is copied above the primary history of a second decode of the
// READY terminal (screens, modes, colors and cursor defaults from local
// policy, continuation, as a READY restore), which is then swapped in
// under the lock. The terminal lock is never held for work that grows
// with the history. The copy stops at this surface's scrollback limits
// (the oldest pages are dropped). An allocation failure while copying
// also drops the oldest pages instead of failing. The renderer can draw
// the READY terminal without the older history for a moment.
//
// Kitty images on a match: the old terminal's stored images and
// placements, which its reflow moved as a resize moves them, go to the
// restored terminal for each screen it has (primary and alternate). A
// pinned placement keeps its distance from the bottom row; one whose row
// the restored terminal does not have is dropped. This surface's Kitty
// limits apply after the move. On a mismatch the images are dropped with
// the history.
//
// When the owner sends the Kitty replay stream
// (ghostty_terminal_kitty_replay_encode, applied with
// ghostty_surface_apply_kitty_replay):
// - after a plain READY restore or a local-history MISMATCH: always, when
//   the owner has images;
// - after a local-history match (RESTORED): not, unless this viewer's
//   Kitty image limits are smaller than the owner's (then the kept images
//   may differ from the owner's after eviction).
// The stream first clears each screen's images, so a replay after a
// RESTORED result never doubles an image or placement.
//
// Returns GHOSTTY_SURFACE_LOCAL_HISTORY_MISMATCH (1) for a mismatch, a
// failed local reflow, or a main-thread change of the live terminal
// between the two swaps (clear screen, reset, resize, set_grid, viewport
// scroll, jump to prompt, a new selection): the READY terminal stays,
// WITHOUT the older history (the old history is discarded), and the
// snapshot is complete. The caller then requests a NEW READY + HISTORY
// (or COMPLETE) snapshot from the owner and applies it with
// ghostty_surface_restore_snapshot.
//
// Returns GHOSTTY_SURFACE_LOCAL_HISTORY_ERROR (-1) for an EXEC surface, a
// malformed or unsupported READY prefix, bytes after READY, a bad digest
// length or a failed decode allocation. It abandons an in-progress
// HISTORY restore; otherwise it changes nothing.
//
// After 0 or 1 a later HISTORY restore returns false. A locked grid takes
// the snapshot's size and keeps its generation. The swap, redraw and
// generation rules are those of a READY restore. Nothing is written to
// io_write_cb.
GHOSTTY_API int ghostty_surface_restore_snapshot_local_history(
    ghostty_surface_t,
    const uint8_t* bytes,
    size_t len,
    uint64_t expected_history_rows,
    const uint8_t* expected_digest,
    size_t digest_len);

// Apply a Kitty image replay stream that the owning libghostty-vt
// terminal wrote with ghostty_terminal_kitty_replay_encode (see
// include/ghostty/vt/terminal.h for the stream). MANUAL modes only; call
// it on the output lane (the thread that calls
// ghostty_surface_process_output), after the snapshot restore and before
// later output. It holds the terminal lock, uses its own trusted parser
// (the output parser and an unfinished sequence that a READY restored
// stay as they are), writes nothing to io_write_cb, and changes only the
// Kitty image storage: each screen's images and placements are replaced
// by the owner's, under this surface's Kitty limits. Only transmit (inline
// data), display and the replay reset run.
//
// Returns false for an EXEC surface, a NULL pointer with a non-zero
// length, an allocation failure, or a stream with skipped parts (bytes
// outside Kitty APC commands, other commands, malformed or truncated
// commands); the valid commands before and after those still ran.
GHOSTTY_API bool ghostty_surface_apply_kitty_replay(ghostty_surface_t,
                                                    const uint8_t*,
                                                    size_t);

// The history digest of a MANUAL or MANUAL_MIRROR surface's primary
// screen: the same value as ghostty_terminal_history_digest computes for
// a libghostty-vt terminal (see ghostty/vt/terminal.h). Call it from the
// output queue; it takes the terminal lock. out_len must be
// GHOSTTY_SURFACE_HISTORY_DIGEST_LEN. Returns false, and writes nothing,
// for an EXEC surface, a NULL pointer or a wrong length.
GHOSTTY_API bool ghostty_surface_history_digest(ghostty_surface_t,
                                                uint64_t* history_rows,
                                                uint8_t* out,
                                                size_t out_len);

// Encode the terminal of a MANUAL or MANUAL_MIRROR surface as a snapshot
// (READY prefix, HISTORY records, or COMPLETE) and pass the bytes to
// write_cb, once, before returning. Call it from the output queue so the
// snapshot matches the output parsed so far. The terminal lock is held
// while encoding, not while write_cb runs. COMPLETE equals the READY
// bytes followed by the HISTORY bytes. Returns false for an EXEC
// surface, an unknown phase, or when the unfinished escape sequence is
// longer than 1 MiB.
GHOSTTY_API bool ghostty_surface_encode_snapshot(
    ghostty_surface_t,
    ghostty_surface_snapshot_write_cb,
    void*,
    ghostty_surface_snapshot_phase_e);

// The GHOSTSNP format version that ghostty_surface_restore_snapshot
// accepts and ghostty_surface_encode_snapshot writes.
GHOSTTY_API uint16_t ghostty_surface_snapshot_version(void);
GHOSTTY_API bool ghostty_surface_mouse_button(ghostty_surface_t,
                                                 ghostty_input_mouse_state_e,
                                                 ghostty_input_mouse_button_e,
                                                 ghostty_input_mods_e);
GHOSTTY_API void ghostty_surface_mouse_pos(ghostty_surface_t,
                                              double,
                                              double,
                                              ghostty_input_mods_e);
GHOSTTY_API void ghostty_surface_mouse_scroll(ghostty_surface_t,
                                                 double,
                                                 double,
                                                 ghostty_input_scroll_mods_t);
GHOSTTY_API void ghostty_surface_mouse_pressure(ghostty_surface_t, uint32_t, double);
GHOSTTY_API void ghostty_surface_ime_point(ghostty_surface_t, double*, double*, double*, double*);
GHOSTTY_API void ghostty_surface_request_close(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_split(ghostty_surface_t, ghostty_action_split_direction_e);
GHOSTTY_API void ghostty_surface_split_focus(ghostty_surface_t,
                                                ghostty_action_goto_split_e);
GHOSTTY_API void ghostty_surface_split_resize(ghostty_surface_t,
                                                 ghostty_action_resize_split_direction_e,
                                                 uint16_t);
GHOSTTY_API void ghostty_surface_split_equalize(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_binding_action(ghostty_surface_t, const char*, uintptr_t);
GHOSTTY_API void ghostty_surface_complete_clipboard_request(
    ghostty_surface_t,
    const ghostty_clipboard_complete_s*,
    void*);
GHOSTTY_API void ghostty_surface_deny_clipboard_request(ghostty_surface_t,
                                                           void*);
GHOSTTY_API bool ghostty_surface_has_selection(ghostty_surface_t);
// Keyboard copy mode on upstream selections: a one-cell selection is the
// copy cursor, and the binding action "adjust_selection:<direction>"
// (ghostty_surface_binding_action) moves its end and scrolls it into view.
// Move without selecting: adjust, read the end, then select that cell.
// Linewise: call ghostty_surface_select_lines after every adjust.
typedef struct {
  // Row relative to the viewport's top row; negative above the viewport,
  // rows or more below it.
  int32_t row;
  // Column of the end cell's glyph lead.
  uint16_t column;
  // 2 for a wide glyph, 1 otherwise.
  uint16_t width_cells;
  bool in_viewport;
} ghostty_surface_selection_end_s;
// Select one visible cell (a wide glyph resolves to its lead). Returns
// false outside the viewport.
GHOSTTY_API bool ghostty_surface_select_viewport_cell(ghostty_surface_t,
                                                      uint16_t column,
                                                      uint16_t row);
// The active selection's moving end. Returns false without a selection.
GHOSTTY_API bool ghostty_surface_selection_end(
    ghostty_surface_t,
    ghostty_surface_selection_end_s*);
// Widen the active selection to whole rows (anchor row to end row), keeping
// its direction. Returns false without a selection.
GHOSTTY_API bool ghostty_surface_select_lines(ghostty_surface_t);
// Clear the active selection. Returns false when there was none.
GHOSTTY_API bool ghostty_surface_clear_selection(ghostty_surface_t);
// Publish the active selection to the standard clipboard as plain text,
// plus HTML when it also fits, each formatted into at most max_bytes. The
// selection is not cleared. Returns false when there is no selection, the
// selection spans more than max_bytes / 4 cells, or its plain text exceeds
// max_bytes.
GHOSTTY_API bool ghostty_surface_copy_selection_to_clipboard_bounded(
    ghostty_surface_t,
    uintptr_t max_bytes);
GHOSTTY_API bool ghostty_surface_read_selection(ghostty_surface_t, ghostty_text_s*);
GHOSTTY_API bool ghostty_surface_read_text(ghostty_surface_t,
                                              ghostty_selection_s,
                                              ghostty_text_s*);
GHOSTTY_API void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*);

#ifdef __APPLE__
GHOSTTY_API void ghostty_surface_set_display_id(ghostty_surface_t, uint32_t);
GHOSTTY_API void* ghostty_surface_quicklook_font(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_quicklook_word(ghostty_surface_t, ghostty_text_s*);
#endif

GHOSTTY_API ghostty_inspector_t ghostty_surface_inspector(ghostty_surface_t);
GHOSTTY_API void ghostty_inspector_free(ghostty_surface_t);
GHOSTTY_API void ghostty_inspector_set_focus(ghostty_inspector_t, bool);
GHOSTTY_API void ghostty_inspector_set_content_scale(ghostty_inspector_t, double, double);
GHOSTTY_API void ghostty_inspector_set_size(ghostty_inspector_t, uint32_t, uint32_t);
GHOSTTY_API void ghostty_inspector_mouse_button(ghostty_inspector_t,
                                                   ghostty_input_mouse_state_e,
                                                   ghostty_input_mouse_button_e,
                                                   ghostty_input_mods_e);
GHOSTTY_API void ghostty_inspector_mouse_pos(ghostty_inspector_t, double, double);
GHOSTTY_API void ghostty_inspector_mouse_scroll(ghostty_inspector_t,
                                                   double,
                                                   double,
                                                   ghostty_input_scroll_mods_t);
GHOSTTY_API void ghostty_inspector_key(ghostty_inspector_t,
                                          ghostty_input_action_e,
                                          ghostty_input_key_e,
                                          ghostty_input_mods_e);
GHOSTTY_API void ghostty_inspector_text(ghostty_inspector_t, const char*);

#ifdef __APPLE__
GHOSTTY_API bool ghostty_inspector_metal_init(ghostty_inspector_t, void*);
GHOSTTY_API void ghostty_inspector_metal_render(ghostty_inspector_t, void*, void*);
GHOSTTY_API bool ghostty_inspector_metal_shutdown(ghostty_inspector_t);
#endif

// APIs I'd like to get rid of eventually but are still needed for now.
// Don't use these unless you know what you're doing.
GHOSTTY_API void ghostty_set_window_background_blur(ghostty_app_t, void*);

// Benchmark API, if available.
GHOSTTY_API bool ghostty_benchmark_cli(const char*, const char*);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_H */
