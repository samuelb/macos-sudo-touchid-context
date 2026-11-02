// pam_tid_context: Touch ID PAM module whose dialog names the command being
// authorized and the process that asked. Mirrors Apple's pam_tid.c guards (GUI
// session, sudo -A askpass) but authenticates via LAContext so it can set
// localizedReason. See docs/how-it-works.md.

#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <crt_externs.h>
#include <ctype.h>
#include <limits.h>
#include <pwd.h>
#include <unistd.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <os/log.h>
#include <errno.h>

// The dialog showed a ~150-character reason in full; longer text is not known to fit.
#define MAX_REASON 160
// Room kept for the requester when the command is long.
#define MIN_REQUESTER 16
// Longest reason a warning shows before cutting it.
#define MAX_WHY 40
#define LOG os_log_create("pam_tid_context", "auth")

// Return nil from a function that has an `NSString **why` parameter, saying why.
#define UNSURE(...) do { if (why) *why = [NSString stringWithFormat:__VA_ARGS__]; return nil; } while (0)

// argv and environment of a process via KERN_PROCARGS2 (layout: int argc, exec
// path, NUL padding, argv strings, environment strings). With `strict`, an
// argument that is not valid UTF-8, or fewer arguments than argc, make the result
// nil instead of "?" placeholders. The environment maps each name to its first
// value (what getenv returns), or to NSNull when that value is not valid UTF-8.
static NSArray<NSString *> *process_args(pid_t pid, BOOL strict, NSDictionary<NSString *, id> **env_out) {
    NSArray *failed = strict ? nil : @[];
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int)) return failed;
    char *buf = malloc(size);
    if (!buf) return failed;
    if (sysctl(mib, 3, buf, &size, NULL, 0) != 0) { free(buf); return failed; }

    int argc;
    memcpy(&argc, buf, sizeof(argc));
    char *p = buf + sizeof(argc), *end = buf + size;
    p += strnlen(p, end - p);                  // skip exec path
    while (p < end && *p == '\0') p++;         // skip padding

    NSMutableArray *args = [NSMutableArray array];
    for (int i = 0; i < argc && p < end; i++) {
        size_t len = strnlen(p, end - p);
        NSString *s = [[NSString alloc] initWithBytes:p length:len encoding:NSUTF8StringEncoding];
        if (!s && strict) { free(buf); return nil; }
        [args addObject:s ?: @"?"];
        p += len + 1;
    }
    if (strict && (int)args.count != argc) { free(buf); return nil; }

    if (env_out) {
        // Everything after argv: the environment, then possibly the kernel's
        // "apple" strings (executable_path=…), whose names never collide with the
        // ones looked up here. Empty strings are skipped, not taken as the end:
        // a caller can put "" in front of a variable to hide it from a naive reader.
        NSMutableDictionary *env = [NSMutableDictionary dictionary];
        while (p < end) {
            size_t len = strnlen(p, end - p);
            char *eq = memchr(p, '=', len);
            if (eq) {
                NSString *name = [[NSString alloc] initWithBytes:p length:eq - p encoding:NSISOLatin1StringEncoding];
                NSString *value = [[NSString alloc] initWithBytes:eq + 1 length:len - (eq + 1 - p)
                                                         encoding:NSUTF8StringEncoding];
                if (name && !env[name]) env[name] = value ?: (id)[NSNull null];
            }
            p += len + 1;
        }
        *env_out = env;
    }
    free(buf);
    return args;
}

static NSArray<NSString *> *process_argv(pid_t pid) {
    return process_args(pid, NO, NULL);
}

static pid_t parent_of(pid_t pid) {
    struct kinfo_proc kp;
    size_t len = sizeof(kp);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len == 0) return 0;
    return kp.kp_eproc.e_ppid;
}

// Never for the command of a normal dialog, only for the requester and the parts of
// a warning. Its input is ASCII after display_word, plus this file's own "→", so no
// character is split.
static NSString *truncated(NSString *s, NSUInteger max) {
    return s.length <= max ? s : [[s substringToIndex:max - 1] stringByAppendingString:@"…"];
}

static BOOL plain_char(unichar c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
           (c && strchr("_@%+=:,./-", (int)c));
}

// One argument as the dialog shows it, written so that it reads back as exactly one
// argument with exactly these characters (bash/zsh quoting):
// - only printable ASCII is shown as it is; anything else (newlines and other
//   control characters, bidi overrides, zero-width and format characters,
//   look-alike letters such as Cyrillic "і") is written as an escape inside $'…';
// - a word with a space or shell punctuation, or an empty word, is single-quoted.
// Without this, a newline in an argument could draw a fake "requested by:" line,
// and `sh -c 'a; b'` and `sh -c 'a;' b` read the same.
static NSString *display_word(NSString *w) {
    BOOL escape = NO, quote = w.length == 0;
    for (NSUInteger i = 0; i < w.length; i++) {
        unichar c = [w characterAtIndex:i];
        if (c < 0x20 || c > 0x7e) escape = YES;
        else if (!plain_char(c)) quote = YES;
    }
    if (!escape && !quote) return w;
    if (!escape) return [NSString stringWithFormat:@"'%@'", [w stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];

    NSMutableString *out = [NSMutableString stringWithString:@"$'"];
    NSData *utf32 = [w dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    if (!utf32) {  // unpaired surrogate: cannot come from UTF-8, but never show it raw
        for (NSUInteger i = 0; i < w.length; i++) [out appendFormat:@"\\u%04X", [w characterAtIndex:i]];
        [out appendString:@"'"];
        return out;
    }
    const uint32_t *cp = utf32.bytes;
    for (NSUInteger i = 0; i < utf32.length / 4; i++) {
        uint32_t c = OSSwapLittleToHostInt32(cp[i]);
        if (c == '\\' || c == '\'') [out appendFormat:@"\\%c", (char)c];
        else if (c == '\n') [out appendString:@"\\n"];
        else if (c == '\t') [out appendString:@"\\t"];
        else if (c == '\r') [out appendString:@"\\r"];
        else if (c >= 0x20 && c <= 0x7e) [out appendFormat:@"%c", (char)c];
        else if (c < 0x20 || c == 0x7f) [out appendFormat:@"\\x%02X", c];
        else if (c <= 0xffff) [out appendFormat:@"\\u%04X", c];
        else [out appendFormat:@"\\U%08X", c];
    }
    [out appendString:@"'"];
    return out;
}

static NSString *display_words(NSArray<NSString *> *words) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:words.count];
    for (NSString *w in words) [out addObject:display_word(w)];
    return [out componentsJoinedByString:@" "];
}

// ---- What sudo will do ------------------------------------------------------------
//
// sudo's own argument parsing, mirrored from parse_args() in sudo 1.9.17p2 as Apple
// ships it (apple-oss-distributions/sudo, tag sudo-114.100.11, sudo/src/parse_args.c):
//
// - getopt_long with "+": options end at the first word that is not one;
// - long options, with "=value" or a separate value, and unique abbreviations
//   (--us root), which macOS getopt_long accepts;
// - grouped short flags and attached values (-Eu root, -uroot);
// - VAR=value words between the options;
// - "--" ends the options only while options are still being read, so a "--" among
//   the command's own arguments belongs to the command.
//
// Whatever this is not sure about returns nil with the reason, and the dialog
// becomes a warning (warning_reason): it must never present a command as certain
// unless it is the one sudo runs. Reasons quote caller-chosen text with
// display_word, because the warning shows them.

enum { NO_ARG, REQ_ARG, OPT_ARG };
enum { OPT_HOST = 256 };

typedef struct { const char *name; int opt; int has_arg; } long_opt;

static const long_opt sudo_long_opts[] = {
    // sudo only
    {"background", 'b', NO_ARG},        {"preserve-env", 'E', OPT_ARG},
    {"edit", 'e', NO_ARG},              {"set-home", 'H', NO_ARG},
    {"login", 'i', NO_ARG},             {"remove-timestamp", 'K', NO_ARG},
    {"list", 'l', NO_ARG},              {"preserve-groups", 'P', NO_ARG},
    {"shell", 's', NO_ARG},             {"other-user", 'U', REQ_ARG},
    {"validate", 'v', NO_ARG},
    // sudo and sudoedit (EDIT_LONG_OPTS)
    {"askpass", 'A', NO_ARG},           {"auth-type", 'a', REQ_ARG},
    {"bell", 'B', NO_ARG},              {"close-from", 'C', REQ_ARG},
    {"login-class", 'c', REQ_ARG},      {"chdir", 'D', REQ_ARG},
    {"group", 'g', REQ_ARG},            {"help", 'h', NO_ARG},
    {"host", OPT_HOST, REQ_ARG},        {"reset-timestamp", 'k', NO_ARG},
    {"no-update", 'N', NO_ARG},         {"non-interactive", 'n', NO_ARG},
    {"prompt", 'p', REQ_ARG},           {"chroot", 'R', REQ_ARG},
    {"role", 'r', REQ_ARG},             {"stdin", 'S', NO_ARG},
    {"command-timeout", 'T', REQ_ARG},  {"type", 't', REQ_ARG},
    {"user", 'u', REQ_ARG},             {"version", 'V', NO_ARG},
};
#define N_LONG_OPTS (sizeof sudo_long_opts / sizeof sudo_long_opts[0])
#define EDIT_LONG_OPTS 11  // sudoedit's long options start at "askpass"
static const char sudo_short_opts[] = "Aa:BbC:c:D:Eeg:Hh::iKklNnPp:R:r:SsT:t:U:u:Vv";
static const char edit_short_opts[] = "Aa:BC:c:D:g:h::KkNnp:R:r:ST:t:u:V";

// How short option c takes a value, or -1 when `opts` does not list it.
static int short_opt(const char *opts, unichar c) {
    if (c == 0 || c == ':' || c > 127) return -1;
    const char *at = strchr(opts, (char)c);
    if (!at) return -1;
    return at[1] != ':' ? NO_ARG : at[2] == ':' ? OPT_ARG : REQ_ARG;
}

// The long option `name` stands for: an exact name, else a prefix of exactly one
// option (or of several that mean the same thing). NULL when unknown or ambiguous.
static const long_opt *find_long_opt(NSString *name, size_t first) {
    if (!name.length) return NULL;
    for (size_t i = first; i < N_LONG_OPTS; i++)
        if ([name isEqualToString:@(sudo_long_opts[i].name)]) return &sudo_long_opts[i];
    const long_opt *match = NULL;
    for (size_t i = first; i < N_LONG_OPTS; i++) {
        const long_opt *o = &sudo_long_opts[i];
        if (![@(o->name) hasPrefix:name]) continue;
        if (match && (match->opt != o->opt || match->has_arg != o->has_arg)) return NULL;
        match = o;
    }
    return match;
}

// sudo's is_envar: a word that sets an environment variable for the command.
static BOOL is_envar(NSString *w) {
    return ![w hasPrefix:@"/"] && ![w hasPrefix:@"="] && [w containsString:@"="];
}

static NSString *invoking_user(void) {
    struct passwd *pw = getpwuid(getuid());
    return pw && pw->pw_name ? @(pw->pw_name) : nil;
}

static NSString *working_directory(void) {
    char cwd[PATH_MAX];
    return getcwd(cwd, sizeof cwd) ? @(cwd) : nil;
}

// The file sudo executes for a command word, found like sudoers' find_path(): a word
// with a "/" is used as it is (relative to the working directory), otherwise the
// caller's PATH is searched in order for a regular, executable file. "." and empty
// entries are only tried after all others, so a match from one is left to the
// password, as are relative entries.
//
// sudoers' secure_path, if set, replaces PATH; macOS does not set it. With it set,
// the path shown can differ from the one sudo runs, but both come from directories
// the caller cannot choose.
static NSString *resolve_command(NSString *word, NSDictionary<NSString *, id> *env, NSString **why) {
    if (word.length >= PATH_MAX) UNSURE(@"command name too long");
    if ([word containsString:@"/"]) {
        if ([word hasPrefix:@"/"]) return word;
        NSString *cwd = working_directory();
        if (!cwd) UNSURE(@"no working directory for %@", display_word(word));
        return [NSString stringWithFormat:@"%@/%@", cwd, word];
    }
    id path = env[@"PATH"];
    if (![path isKindOfClass:[NSString class]]) UNSURE(@"PATH is unset or not UTF-8");
    BOOL dot = NO;
    for (NSString *dir in [path componentsSeparatedByString:@":"]) {
        if (!dir.length || [dir isEqualToString:@"."]) { dot = YES; continue; }
        if (![dir hasPrefix:@"/"]) UNSURE(@"relative PATH entry %@", display_word(dir));
        NSString *candidate = [NSString stringWithFormat:@"%@/%@", dir, word];
        struct stat st;
        if (stat(candidate.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode) && (st.st_mode & 0111))
            return candidate;
    }
    if (dot) UNSURE(@"%@ could only come from . in PATH", display_word(word));
    UNSURE(@"%@ is not in PATH", display_word(word));
}

// The single -c argument sudo builds for `sudo -s/-i <command>`: a backslash before
// every character that is not alphanumeric, '_', '-' or '$', words joined by spaces.
static NSString *sudo_shell_command(NSArray<NSString *> *words) {
    NSMutableString *out = [NSMutableString string];
    for (NSString *w in words) {
        if (out.length) [out appendString:@" "];
        for (NSUInteger k = 0; k < w.length;) {
            NSRange r = [w rangeOfComposedCharacterSequenceAtIndex:k];
            unichar c = [w characterAtIndex:k];
            if (!(r.length == 1 && c < 128 && (isalnum(c) || c == '_' || c == '-' || c == '$')))
                [out appendString:@"\\"];
            [out appendString:[w substringWithRange:r]];
            k = NSMaxRange(r);
        }
    }
    return out;
}

// What sudo will do with these arguments, as dialog text ("run: …", "run as
// postgres: …", "edit: …"), or nil with the reason in *why.
static NSString *describe_sudo(NSArray<NSString *> *argv, NSDictionary<NSString *, id> *env, NSString **why) {
    if (!argv.count) UNSURE(@"no arguments");
    BOOL as_sudoedit = [argv[0].lastPathComponent isEqualToString:@"sudoedit"];
    const char *shorts = as_sudoedit ? edit_short_opts : sudo_short_opts;
    size_t first_long = as_sudoedit ? EDIT_LONG_OPTS : 0;

    __block int mode = as_sudoedit ? 'e' : 0;  // 'e' edit, 'l' list, 'v' validate, 0 run
    __block BOOL shell = NO, login = NO, preserve_env = NO, reset_ticket = NO;
    __block NSString *user = nil, *group = nil, *list_user = nil, *unsure = nil;
    NSMutableArray<NSString *> *env_add = [NSMutableArray array];

    BOOL (^apply)(int, NSString *) = ^BOOL(int o, NSString *v) {
        switch (o) {
            case 'A': case 'B': case 'b': case 'H': case 'N': case 'n': case 'P': case 'S':
            case 'C': case 'T': case 'p':  // -p is sudo's own password prompt
                return YES;
            case 'k':
                reset_ticket = YES;
                return YES;
            case 'E':
                if (!v) { preserve_env = YES; return YES; }
                // --preserve-env=A,B passes those variables from the caller's
                // environment, the same as A=… B=… on the command line.
                for (NSString *name in [v componentsSeparatedByString:@","]) {
                    if (!name.length) continue;
                    id val = env[name];
                    if ([name containsString:@"="] || val == [NSNull null]) {
                        unsure = [NSString stringWithFormat:@"--preserve-env=%@", display_word(v)];
                        return NO;
                    }
                    if (val) [env_add addObject:[NSString stringWithFormat:@"%@=%@", name, val]];
                }
                return YES;
            case 'e': case 'l': case 'v':
                if (mode && mode != o) { unsure = @"more than one mode"; return NO; }
                mode = o;
                return YES;
            case 'i': login = YES; return YES;
            case 's': shell = YES; return YES;
            case 'u': case 'g':
                if (!v.length || (o == 'u' ? user : group)) { unsure = @"bad -u/-g"; return NO; }
                if (o == 'u') user = v; else group = v;
                return YES;
            case 'U':
                list_user = v;
                return YES;
            case 'D': case 'R':
                unsure = @"-D/-R change where the command runs";
                return NO;
            case 'h': case OPT_HOST:
                unsure = @"-h/--host";
                return NO;
            case 'K': case 'V':
                unsure = @"-K/-V do not run anything";
                return NO;
            default:  // -a, -c, -r, -t: not built into sudo on macOS
                unsure = [NSString stringWithFormat:@"-%c is not supported by sudo on macOS", o];
                return NO;
        }
    };

    NSUInteger i = 1;
    while (i < argv.count) {
        NSString *w = argv[i];
        if ([w isEqualToString:@"--"]) { i++; break; }
        if ([w hasPrefix:@"--"]) {
            NSString *body = [w substringFromIndex:2];
            NSRange eq = [body rangeOfString:@"="];
            NSString *name = eq.location == NSNotFound ? body : [body substringToIndex:eq.location];
            const long_opt *o = find_long_opt(name, first_long);
            if (!o) UNSURE(@"unknown or ambiguous option --%@", display_word(name));
            i++;
            NSString *value = nil;
            if (eq.location != NSNotFound) {
                if (o->has_arg == NO_ARG) UNSURE(@"--%s takes no value", o->name);
                value = [body substringFromIndex:eq.location + 1];
            } else if (o->has_arg == REQ_ARG) {
                if (i >= argv.count) UNSURE(@"--%s needs a value", o->name);
                value = argv[i++];
            }
            if (!apply(o->opt, value)) UNSURE(@"%@", unsure);
            continue;
        }
        if ([w hasPrefix:@"-"] && w.length > 1) {
            i++;
            for (NSUInteger k = 1; k < w.length; k++) {
                unichar c = [w characterAtIndex:k];
                int kind = short_opt(shorts, c);
                if (kind < 0) UNSURE(@"unknown option -%@", display_word([NSString stringWithCharacters:&c length:1]));
                NSString *rest = k + 1 < w.length ? [w substringFromIndex:k + 1] : nil;
                if (kind == NO_ARG) {
                    if (!apply(c, nil)) UNSURE(@"%@", unsure);
                    continue;
                }
                if (kind == REQ_ARG && !rest) {
                    if (i >= argv.count) UNSURE(@"-%C needs a value", c);
                    rest = argv[i++];
                }
                if (!apply(c, rest)) UNSURE(@"%@", unsure);
                break;  // the value used up the rest of the word
            }
            continue;
        }
        // Not an option: a VAR=value word, unless the word before was "--" (sudo's
        // got_end_of_args looks only at the previous word), or else the command.
        if (![argv[i - 1] isEqualToString:@"--"] && is_envar(w)) {
            [env_add addObject:w];
            i++;
            continue;
        }
        break;
    }
    NSArray<NSString *> *cmd = [argv subarrayWithRange:NSMakeRange(i, argv.count - i)];

    // The checks sudo makes after parsing; a combination it rejects never reaches PAM.
    if (!mode) {
        if (reset_ticket && !cmd.count && !shell && !login) UNSURE(@"sudo -k does not run anything");
        mode = 'r';
    }
    if (mode == 'l' && cmd.count) mode = 'c';
    if (login && (shell || preserve_env)) UNSURE(@"-i with -s or -E");
    if (mode != 'r' && (shell || login || preserve_env)) UNSURE(@"-s/-i/-E outside run mode");
    if (mode == 'e' && env_add.count) UNSURE(@"environment variables in edit mode");
    if ((user || group) && mode == 'l') UNSURE(@"-u/-g with -l");
    if (list_user && mode != 'l' && mode != 'c') UNSURE(@"-U without -l");
    if (mode == 'e' && !cmd.count) UNSURE(@"nothing to edit");
    if (cmd.count && mode != 'r' && mode != 'e' && mode != 'c') UNSURE(@"a command after -v");
    if (mode == 'r' && !cmd.count && !shell && !login) UNSURE(@"sudo without a command");

    NSString *me = invoking_user();
    if (!me) UNSURE(@"no passwd entry for uid %d", getuid());
    NSString *target = user ?: (group ? me : @"root");  // -g alone runs as the caller
    NSMutableString *as = [NSMutableString string];
    if (![target isEqualToString:@"root"] && ![target isEqualToString:@"#0"]) [as appendFormat:@" as %@", display_word(target)];
    if (group) [as appendFormat:@" with group %@", display_word(group)];

    // Variables set for the command. Homebrew passes LOGNAME, USER and USERNAME set
    // to the caller's own name, which change nothing worth a line in the dialog.
    NSMutableArray<NSString *> *shown_env = [NSMutableArray array];
    for (NSString *kv in env_add) {
        NSRange eq = [kv rangeOfString:@"="];
        NSString *name = [kv substringToIndex:eq.location], *value = [kv substringFromIndex:NSMaxRange(eq)];
        if ([@[@"LOGNAME", @"USER", @"USERNAME"] containsObject:name] && [value isEqualToString:me]) continue;
        [shown_env addObject:kv];
    }

    switch (mode) {
        case 'v':
            return @"refresh your cached sudo credentials";
        case 'l':
            return list_user ? [NSString stringWithFormat:@"list the sudo rights of %@", display_word(list_user)]
                             : @"list your sudo rights";
        case 'c':
            return [NSString stringWithFormat:@"check whether %@ may run: %@",
                                              list_user ? display_word(list_user) : @"you", display_words(cmd)];
        case 'e': {
            NSMutableArray *files = [NSMutableArray array];
            NSString *cwd = working_directory();
            for (NSString *f in cmd) {
                if (![f hasPrefix:@"/"] && !cwd) UNSURE(@"no working directory for %@", display_word(f));
                [files addObject:[f hasPrefix:@"/"] ? f : [NSString stringWithFormat:@"%@/%@", cwd, f]];
            }
            return [NSString stringWithFormat:@"edit%@: %@", as, display_words(files)];
        }
    }

    NSArray<NSString *> *run;
    NSString *kind = @"";
    if (shell || login) {
        NSString *sh = nil;
        if (login) {  // the target user's login shell
            struct passwd *pw = NULL;
            if ([target hasPrefix:@"#"]) {
                NSString *digits = [target substringFromIndex:1];
                if (!digits.length || [digits rangeOfCharacterFromSet:
                        [NSCharacterSet decimalDigitCharacterSet].invertedSet].location != NSNotFound)
                    UNSURE(@"bad uid %@", display_word(target));
                pw = getpwuid((uid_t)strtoul(digits.UTF8String, NULL, 10));
            } else {
                pw = getpwnam(target.UTF8String);
            }
            if (pw && pw->pw_shell) sh = @(pw->pw_shell);
            kind = @" (login shell)";
        } else {  // $SHELL, else the caller's shell from the user database
            id s = env[@"SHELL"];
            if (s == [NSNull null]) UNSURE(@"SHELL is not UTF-8");
            if ([s length]) {
                sh = s;
            } else {
                struct passwd *pw = getpwuid(getuid());
                if (pw && pw->pw_shell) sh = @(pw->pw_shell);
            }
        }
        if (![sh hasPrefix:@"/"]) UNSURE(@"shell %@ is not an absolute path", sh ? display_word(sh) : @"(none)");
        run = cmd.count ? @[sh, @"-c", sudo_shell_command(cmd)] : @[sh];
    } else {
        NSString *path = resolve_command(cmd[0], env, why);
        if (!path) return nil;
        run = [@[path] arrayByAddingObjectsFromArray:[cmd subarrayWithRange:NSMakeRange(1, cmd.count - 1)]];
    }
    return [NSString stringWithFormat:@"run%@%@: %@", as, kind,
                                      display_words([shown_env arrayByAddingObjectsFromArray:run])];
}

// Absolute paths shortened to their last component, e.g. the portable-ruby path brew runs under.
static NSArray<NSString *> *basenames(NSArray<NSString *> *words) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:words.count];
    for (NSString *w in words) [out addObject:[w hasPrefix:@"/"] ? w.lastPathComponent : w];
    return out;
}

static NSString *shell_name(NSArray<NSString *> *argv) {
    if (!argv.count) return nil;
    NSString *name = [argv[0] hasPrefix:@"-"] ? [argv[0] substringFromIndex:1] : argv[0].lastPathComponent;
    return [@[@"sh", @"bash", @"zsh", @"dash", @"ksh", @"fish"] containsObject:name] ? name : nil;
}

// `sh -c '<inline script>'` says nothing about who asked; a script file or an interactive shell does.
static BOOL is_inline_shell(NSArray<NSString *> *argv) {
    return shell_name(argv) && argv.count > 1 && [argv[1] hasPrefix:@"-"] && [argv[1] containsString:@"c"];
}

// "ruby -W1 --disable=gems brew.rb upgrade" -> "brew.rb upgrade": the script names the requester.
static NSArray<NSString *> *without_interpreter(NSArray<NSString *> *argv) {
    static NSArray *interpreters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ interpreters = @[@"ruby", @"python", @"python3", @"perl", @"node", @"bun", @"deno"]; });
    if (!argv.count || ![interpreters containsObject:argv[0].lastPathComponent]) return argv;
    NSUInteger i = 1;
    while (i < argv.count && [argv[i] hasPrefix:@"-"]) i++;
    return i < argv.count ? [argv subarrayWithRange:NSMakeRange(i, argv.count - i)] : argv;
}

// First ancestor that is not an inline `shell -c` wrapper, e.g. "claude (via zsh -c)".
static NSString *requester(void) {
    NSMutableArray *via = [NSMutableArray array];
    pid_t pid = parent_of(getpid());
    NSArray *argv = process_argv(pid);
    for (int hops = 0; hops < 8 && pid > 1 && is_inline_shell(argv); hops++) {
        [via addObject:[shell_name(argv) stringByAppendingString:@" -c"]];
        pid = parent_of(pid);
        argv = process_argv(pid);
    }
    if (!argv.count) return @"unknown";
    NSMutableArray *words = [basenames(without_interpreter(argv)) mutableCopy];
    if ([words[0] hasPrefix:@"-"]) words[0] = [words[0] substringFromIndex:1];  // login shell "-zsh"
    NSString *who = display_words(words);
    return via.count ? [NSString stringWithFormat:@"%@ (via %@)", truncated(who, 50),
                                  [[[via reverseObjectEnumerator] allObjects] componentsJoinedByString:@" → "]]
                     : who;
}

static NSString *const REQUESTED_BY = @" — requested by: ";

// display_word for bytes that may not be UTF-8; those are shown as \xHH escapes.
static NSString *display_bytes(const char *s) {
    NSString *w = [NSString stringWithUTF8String:s];
    if (w) return display_word(w);
    NSMutableString *out = [NSMutableString stringWithString:@"$'"];
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (*p == '\\' || *p == '\'') [out appendFormat:@"\\%c", *p];
        else if (*p >= 0x20 && *p <= 0x7e) [out appendFormat:@"%c", *p];
        else [out appendFormat:@"\\x%02X", *p];
    }
    [out appendString:@"'"];
    return out;
}

// How sudo was called, from its own memory: an empty argv[0] or bytes that are not
// UTF-8 are shown as they are. argv[0] is shortened to its last path component.
static NSString *sudo_call(void) {
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    if (argc < 1 || !argv || !argv[0]) return nil;
    NSMutableArray *words = [NSMutableArray arrayWithCapacity:argc];
    const char *name = strrchr(argv[0], '/');
    [words addObject:display_bytes(name ? name + 1 : argv[0])];
    for (int i = 1; i < argc && argv[i]; i++) [words addObject:display_bytes(argv[i])];
    return [words componentsJoinedByString:@" "];
}

// What sudo will do, as dialog text, or nil with the reason in *why.
static NSString *sudo_description(NSString **why) {
    // KERN_PROCARGS2 cannot tell an empty argv[0] from the NUL padding in front of
    // it, which would shift every argument by one; sudo itself sees the real argv.
    char **real_argv = *_NSGetArgv();
    if (*_NSGetArgc() < 1 || !real_argv[0] || !real_argv[0][0]) UNSURE(@"sudo's argv[0] is empty");
    NSDictionary *env = nil;
    NSArray *argv = process_args(getpid(), YES, &env);
    if (!argv) UNSURE(@"arguments not readable or not UTF-8");
    if ((int)argv.count != *_NSGetArgc()) UNSURE(@"sudo's argument count does not match");
    return describe_sudo(argv, env, why);
}

// The dialog when the module cannot say for sure what sudo will do: a warning with
// the reason, how sudo was called (a clue to find out more, but not a statement of
// what runs), and the requester. The warning comes first and is never cut away;
// the other parts are cut to fit.
static NSString *warning_reason(NSString *why, NSString *call, NSString *from) {
    NSString *start = @"run an UNVERIFIED command (", *label = @"), called as: ";
    NSString *w = truncated(why, MAX_WHY);
    NSUInteger room = MAX_REASON - start.length - w.length - label.length - REQUESTED_BY.length;
    NSString *c = truncated(call, room - MIN(from.length, MIN_REQUESTER));
    NSString *r = truncated(from, room - c.length);
    return [NSString stringWithFormat:@"%@%@%@%@%@%@", start, w, label, c, REQUESTED_BY, r];
}

// The dialog text. When the module cannot say for sure what sudo will do, *why says
// why and the text is a warning. nil only when not even sudo's arguments are there.
static NSString *build_reason(NSString **why) {
    *why = nil;
    NSString *what = sudo_description(why);
    NSString *from = requester();

    // The command is never shortened in a normal dialog: a cut hides exactly the
    // part that matters (`sh -c "<100 spaces>; evil"`). If it does not fit, the
    // dialog becomes a warning. Only the requester, which the caller can choose
    // anyway, is cut.
    NSUInteger room = MAX_REASON - REQUESTED_BY.length;
    if (what) {
        if (what.length + MIN_REQUESTER <= room)
            return [NSString stringWithFormat:@"%@%@%@", what, REQUESTED_BY, truncated(from, room - what.length)];
        *why = [NSString stringWithFormat:@"too long to show in full: %lu characters", (unsigned long)what.length];
    }
    NSString *call = sudo_call();
    return call ? warning_reason(*why ?: @"unknown reason", call, from) : nil;
}

static BOOL in_aqua_session(void) {
    // Same intent as pam_tid's VPROCMGR_SESSION_AQUA check: only prompt when a GUI is there.
    uid_t console_uid = (uid_t)-1;
    CFStringRef user = SCDynamicStoreCopyConsoleUser(NULL, &console_uid, NULL);
    if (user) CFRelease(user);
    return user != NULL && console_uid != (uid_t)-1;
}

// Only accept the fingerprint for the user sitting at the console, and only when
// that user is the one authenticating (LAContext's policy ignores the PAM user).
static BOOL target_is_console_user(const char *pam_user) {
    struct passwd *pw = getpwnam(pam_user);
    if (!pw) return NO;
    uid_t console_uid = (uid_t)-1;
    CFStringRef user = SCDynamicStoreCopyConsoleUser(NULL, &console_uid, NULL);
    if (user) CFRelease(user);
    return user != NULL && pw->pw_uid == console_uid && getuid() == console_uid;
}

static int evaluate(NSString *reason) {
    LAContext *ctx = [LAContext new];
    NSError *err = nil;
    if (![ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&err]) {
        os_log(LOG, "Touch ID unavailable: %{public}@", err.localizedDescription);
        return PAM_AUTHINFO_UNAVAIL;
    }
    os_log(LOG, "prompting: %{public}@", reason);

    __block BOOL ok = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
        localizedReason:reason
                  reply:^(BOOL success, NSError *e) {
                      ok = success;
                      if (!success) os_log(LOG, "declined: %{public}@", e.localizedDescription);
                      dispatch_semaphore_signal(done);
                  }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return ok ? PAM_SUCCESS : PAM_AUTH_ERR;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    @autoreleasepool {
        const char *user = NULL;
        if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || !user) return PAM_AUTHINFO_UNAVAIL;
        if (!in_aqua_session()) { os_log(LOG, "skip: no GUI session"); return PAM_AUTHINFO_UNAVAIL; }

        const void *askpass = NULL;
        if (pam_get_data(pamh, "askpass-enabled", &askpass) == PAM_SUCCESS) {
            os_log(LOG, "skip: sudo -A askpass mode");
            return PAM_AUTHINFO_UNAVAIL;
        }

        if (!target_is_console_user(user)) {
            os_log(LOG, "skip: %{public}s is not the console user / invoking user", user);
            return PAM_AUTHINFO_UNAVAIL;
        }

        // Built before the euid switch: PATH is searched as root, as sudoers does first.
        NSString *why = nil;
        NSString *reason = build_reason(&why);
        if (!reason) {
            os_log(LOG, "skip: %{public}@; sudo asks for the password instead", why);
            return PAM_AUTHINFO_UNAVAIL;
        }
        if (why) os_log(LOG, "unverified: %{public}@; the dialog shows a warning", why);

        // coreauthd evaluates for the caller's effective uid; inside setuid sudo that is
        // root, who has no enrolled fingers ("No identities are enrolled"). Drop to the
        // invoking user for the evaluation only.
        uid_t saved_euid = geteuid();
        if (saved_euid != getuid() && seteuid(getuid()) != 0) {
            os_log_error(LOG, "seteuid(%d) failed: %{errno}d", getuid(), errno);
            return PAM_AUTHINFO_UNAVAIL;
        }
        int rc = evaluate(reason);
        if (geteuid() != saved_euid && seteuid(saved_euid) != 0) {
            os_log_fault(LOG, "cannot restore euid %d: %{errno}d", saved_euid, errno);
            abort();
        }
        return rc;
    }
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    return PAM_SUCCESS;
}
