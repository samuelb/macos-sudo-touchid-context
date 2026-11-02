// Checks of module functions that need neither a dialog nor root. Prints one
// "ok"/"FAIL" line per check and exits non-zero if any fails.
#include "../src/pam_tid_context.m"

static int failed = 0;

static void check(const char *label, int want, int got) {
    if (got == want) {
        printf("ok   %s\n", label);
    } else {
        printf("FAIL %s\n     want: %d\n     got:  %d\n", label, want, got);
        failed = 1;
    }
}

int main(void) {
    // An exception, which would otherwise abort sudo, makes it ask for the password.
    // (Putting back the effective uid needs setuid sudo; here it is unchanged.)
    uid_t euid = geteuid();
    check("result passed through", PAM_SUCCESS, run_guarded(euid, ^{ return PAM_SUCCESS; }));
    check("thrown exception: password instead", PAM_AUTHINFO_UNAVAIL, run_guarded(euid, ^int {
        @throw [NSException exceptionWithName:NSGenericException reason:@"test" userInfo:nil];
    }));
    check("Foundation exception: password instead", PAM_AUTHINFO_UNAVAIL, run_guarded(euid, ^int {
        (void)[@[] objectAtIndex:1];
        return PAM_SUCCESS;
    }));
    check("effective uid unchanged", (int)euid, (int)geteuid());

    // On an account line the module must not approve anything.
    check("account check: ignored", PAM_IGNORE, pam_sm_acct_mgmt(NULL, 0, 0, NULL));
    return failed;
}
