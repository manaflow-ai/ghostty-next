// ghostty-next GhosttyKit link-and-run smoke: init the library and print its
// build info. Exit 0 on success.
#include <stdio.h>
#include "ghostty.h"
int main(int argc, char **argv) {
    if (ghostty_init((uintptr_t)argc, argv) != GHOSTTY_SUCCESS) { fprintf(stderr, "ghostty_init failed\n"); return 1; }
    ghostty_info_s info = ghostty_info();
    printf("ghostty ok: version=%.*s build_mode=%d\n", (int)info.version_len, info.version, (int)info.build_mode);
    ghostty_config_t cfg = ghostty_config_new();
    if (!cfg) { fprintf(stderr, "config_new failed\n"); return 2; }
    ghostty_config_finalize(cfg);
    ghostty_config_free(cfg);
    printf("config ok\n");
    return 0;
}
