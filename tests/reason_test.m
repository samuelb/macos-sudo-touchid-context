// Prints the reason string the module would show, without prompting Touch ID, or
// "fallback: <why>" when the module would leave sudo to ask for the password.
// Invoke it with sudo-shaped arguments from different parents to exercise the
// command parser and the requester walk (see tests/check-reasons.sh).
#include "../src/pam_tid_context.m"

int main(void) {
    @autoreleasepool {
        NSString *why = nil;
        NSString *reason = build_reason(&why);
        printf("%s\n", reason ? reason.UTF8String : [@"fallback: " stringByAppendingString:why].UTF8String);
    }
    return 0;
}
