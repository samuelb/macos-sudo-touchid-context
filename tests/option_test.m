// Prints the settings the module takes from the given module options (the words
// after the module path on its sudo_local line). See tests/check-options.sh.
#include "../src/pam_tid_context.m"

int main(int argc, const char **argv) {
    module_options o = parse_options(argc - 1, argv + 1);
    printf("timeout=%d%s\n", o.timeout, o.audit ? " audit" : "");
    return 0;
}
