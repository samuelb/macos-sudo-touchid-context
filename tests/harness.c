// Loads the module and calls its pam_sm_authenticate directly with a real PAM
// handle: no /etc/pam.d entry and no sudo involved. Shows a real Touch ID dialog.
// Pass sudo-shaped arguments (e.g. `harness -E -- /usr/sbin/installer -pkg x.pkg`)
// so the module parses this process's argv the way it would parse sudo's. Module
// options, the words after the module path on a sudo_local line, come from
// MODULE_OPTIONS (e.g. MODULE_OPTIONS=timeout=5).
//
// Runs as the invoking user, so it does not exercise the euid switch that only
// happens inside setuid sudo; `just try-sudo` covers that.

#include <security/pam_appl.h>
#include <dlfcn.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int (*pam_sm_fn)(pam_handle_t *, int, int, const char **);

static int null_conv(int n, const struct pam_message **m, struct pam_response **r, void *d) {
    return PAM_CONV_ERR;
}

int main(void) {
    const char *module = getenv("MODULE") ? getenv("MODULE") : "build/pam_tid_context.so";
    void *h = dlopen(module, RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    pam_sm_fn auth = (pam_sm_fn)dlsym(h, "pam_sm_authenticate");
    if (!auth) { fprintf(stderr, "dlsym: %s\n", dlerror()); return 2; }

    struct pam_conv conv = {null_conv, NULL};
    pam_handle_t *pamh = NULL;
    int rc = pam_start("pam_tid_context_harness", getpwuid(getuid())->pw_name, &conv, &pamh);
    if (rc != PAM_SUCCESS) { fprintf(stderr, "pam_start: %d\n", rc); return 2; }

    const char *opts[16];
    int nopts = 0;
    char *spec = getenv("MODULE_OPTIONS") ? strdup(getenv("MODULE_OPTIONS")) : NULL;
    for (char *w = spec ? strtok(spec, " \t") : NULL; w && nopts < 16; w = strtok(NULL, " \t")) opts[nopts++] = w;

    rc = auth(pamh, 0, nopts, opts);
    printf("pam_sm_authenticate -> %d (%s)\n", rc, pam_strerror(pamh, rc));
    pam_end(pamh, rc);
    return rc == PAM_SUCCESS ? 0 : 1;
}
