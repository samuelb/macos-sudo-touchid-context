// Prints the dialog timeout the module uses for the given module options (the words
// after the module path on its sudo_local line). See tests/check-options.sh.
#include "../src/pam_tid_context.m"

int main(int argc, const char **argv) {
    printf("%d\n", dialog_timeout(argc - 1, argv + 1));
    return 0;
}
