// apple-tasks-private: write-only native Reminders tag mirror.
//
// Uses Apple's PRIVATE ReminderKit framework (unsupported; may break on any
// macOS update). Loaded via dlopen + NSClassFromString so this binary builds
// and runs even if the framework changes — every class and selector is probed
// before use and failures come back as clean JSON errors.
//
// Protocol: one JSON object on stdin. Two independent operations, either or
// both per call (keyed by which fields are present):
//   Tags (additive mirror):
//     {"externalId": "<EKReminder externalId>", "tags": ["a","b"]}
//   Subtask (IDEAS #26): make externalId a subtask of a parent, or detach it:
//     {"externalId": "<child>", "parent": "<parent externalId>"}
//     {"externalId": "<child>", "clearParent": true}
// Success: {"ok":true,"tagged":N,"parent":"set|cleared"} on stdout (fields
// present only for operations performed). Failure: {"error":"..."} on stderr, exit 1.
//
// Tag removal is intentionally absent: ReminderKit's hashtag change context
// only exposes addHashtagWithType:name:. The [tag] title prefix remains the
// source of truth; this mirror is additive only. Sections are not yet
// mirrored (the reminder->section reference is unproven); subtasks are.

#import <Foundation/Foundation.h>
#include <dlfcn.h>

@interface REMObjectID : NSObject
+ (id)objectIDWithURL:(NSURL *)url;
@end

@interface REMStore : NSObject
- (id)fetchReminderWithObjectID:(id)objectID error:(NSError **)error;
@end

@interface REMSaveRequest : NSObject
- (instancetype)initWithStore:(id)store;
- (id)updateReminder:(id)reminder;
- (BOOL)saveSynchronouslyWithError:(NSError **)error;
@end

@interface REMReminderChangeItem : NSObject
- (id)hashtagContext;
- (id)subtaskContext;
- (void)removeFromParentReminder;
@end

@interface REMReminderHashtagContextChangeItem : NSObject
- (id)addHashtagWithType:(NSInteger)type name:(NSString *)name;
@end

@interface REMReminderSubtaskContextChangeItem : NSObject
- (void)addReminderChangeItem:(id)changeItem;
@end

static void failJSON(NSString *message) {
    NSDictionary *payload = @{ @"error": message ?: @"unknown error" };
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    fwrite(data.bytes, 1, data.length, stderr);
    fputc('\n', stderr);
    exit(1);
}

static Class requireClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) {
        failJSON([NSString stringWithFormat:
            @"ReminderKit class %@ not found — private API changed on this macOS; native tag mirroring unavailable", name]);
    }
    return cls;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (!dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit", RTLD_LAZY)) {
            failJSON(@"could not load ReminderKit framework");
        }

        // --check: probe the private API surface without writing anything.
        if (argc > 1 && strcmp(argv[1], "--check") == 0) {
            Class objectIDClass = requireClass(@"REMObjectID");
            requireClass(@"REMStore");
            requireClass(@"REMSaveRequest");
            if (![objectIDClass respondsToSelector:@selector(objectIDWithURL:)]) failJSON(@"REMObjectID.objectIDWithURL: missing");
            Class changeClass = NSClassFromString(@"REMReminderChangeItem");
            if (!changeClass || ![changeClass instancesRespondToSelector:@selector(hashtagContext)]) failJSON(@"REMReminderChangeItem.hashtagContext missing");
            Class hashtagClass = NSClassFromString(@"REMReminderHashtagContextChangeItem");
            if (!hashtagClass || ![hashtagClass instancesRespondToSelector:@selector(addHashtagWithType:name:)]) failJSON(@"addHashtagWithType:name: missing");
            // Subtask surface (IDEAS #26): probe but don't fail the whole
            // check if only this is missing — tags remain the critical path.
            BOOL subtasks = changeClass
                && [changeClass instancesRespondToSelector:@selector(subtaskContext)]
                && [changeClass instancesRespondToSelector:@selector(removeFromParentReminder)];
            Class subtaskClass = NSClassFromString(@"REMReminderSubtaskContextChangeItem");
            subtasks = subtasks && subtaskClass
                && [subtaskClass instancesRespondToSelector:@selector(addReminderChangeItem:)];
            printf("{\"ok\":true,\"mode\":\"check\",\"subtasks\":%s}\n", subtasks ? "true" : "false");
            return 0;
        }

        NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        NSError *error = nil;
        NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:input options:0 error:&error];
        if (![cmd isKindOfClass:[NSDictionary class]]) failJSON(@"stdin must be a JSON object");

        NSString *externalId = cmd[@"externalId"];
        NSArray *tags = cmd[@"tags"];
        NSString *parentId = cmd[@"parent"];
        BOOL clearParent = [cmd[@"clearParent"] boolValue];
        if (![externalId isKindOfClass:[NSString class]] || externalId.length == 0) failJSON(@"missing externalId");
        BOOL wantTags = [tags isKindOfClass:[NSArray class]] && tags.count > 0;
        BOOL wantParent = [parentId isKindOfClass:[NSString class]] && parentId.length > 0;
        if (!wantTags && !wantParent && !clearParent) failJSON(@"nothing to do (need tags, parent, or clearParent)");

        Class objectIDClass = requireClass(@"REMObjectID");
        Class storeClass = requireClass(@"REMStore");
        Class saveClass = requireClass(@"REMSaveRequest");
        if (![objectIDClass respondsToSelector:@selector(objectIDWithURL:)]) failJSON(@"REMObjectID.objectIDWithURL: missing");

        id (^fetch)(NSString *) = ^id(NSString *ext) {
            NSString *urlString = [NSString stringWithFormat:@"x-apple-reminderkit://REMCDReminder/%@", ext];
            id oid = [(Class)objectIDClass objectIDWithURL:[NSURL URLWithString:urlString]];
            if (!oid) failJSON([NSString stringWithFormat:@"could not build object ID for %@", ext]);
            return oid;
        };

        REMStore *store = (REMStore *)[storeClass new];
        if (![store respondsToSelector:@selector(fetchReminderWithObjectID:error:)]) failJSON(@"REMStore.fetchReminderWithObjectID:error: missing");
        id reminder = [store fetchReminderWithObjectID:fetch(externalId) error:&error];
        if (!reminder) {
            failJSON([NSString stringWithFormat:@"reminder not found for externalId %@: %@",
                      externalId, error.localizedDescription ?: @"no error detail"]);
        }

        REMSaveRequest *save = [(REMSaveRequest *)[saveClass alloc] initWithStore:store];
        if (![save respondsToSelector:@selector(updateReminder:)]) failJSON(@"REMSaveRequest.updateReminder: missing");
        REMReminderChangeItem *change = [save updateReminder:reminder];

        NSMutableDictionary *result = [@{ @"ok": @YES } mutableCopy];

        if (wantTags) {
            if (![change respondsToSelector:@selector(hashtagContext)]) failJSON(@"REMReminderChangeItem.hashtagContext missing");
            REMReminderHashtagContextChangeItem *hashtagContext = [change hashtagContext];
            if (![hashtagContext respondsToSelector:@selector(addHashtagWithType:name:)]) failJSON(@"hashtag addHashtagWithType:name: missing");
            NSInteger tagged = 0;
            for (id tag in tags) {
                if (![tag isKindOfClass:[NSString class]] || [tag length] == 0) continue;
                [hashtagContext addHashtagWithType:1 name:tag];
                tagged++;
            }
            if (tagged == 0) failJSON(@"no valid tags provided");
            result[@"tagged"] = @(tagged);
        }

        if (clearParent) {
            if (![change respondsToSelector:@selector(removeFromParentReminder)]) failJSON(@"removeFromParentReminder missing (subtask API changed)");
            [change removeFromParentReminder];
            result[@"parent"] = @"cleared";
        } else if (wantParent) {
            id parentReminder = [store fetchReminderWithObjectID:fetch(parentId) error:&error];
            if (!parentReminder) {
                failJSON([NSString stringWithFormat:@"parent reminder not found for externalId %@: %@",
                          parentId, error.localizedDescription ?: @"no error detail"]);
            }
            REMReminderChangeItem *parentChange = [save updateReminder:parentReminder];
            if (![parentChange respondsToSelector:@selector(subtaskContext)]) failJSON(@"subtaskContext missing (subtask API changed)");
            REMReminderSubtaskContextChangeItem *subtaskContext = [parentChange subtaskContext];
            if (![subtaskContext respondsToSelector:@selector(addReminderChangeItem:)]) failJSON(@"addReminderChangeItem: missing (subtask API changed)");
            [subtaskContext addReminderChangeItem:change];
            result[@"parent"] = @"set";
        }

        if (![save saveSynchronouslyWithError:&error]) {
            failJSON([NSString stringWithFormat:@"ReminderKit save failed: %@",
                      error.localizedDescription ?: @"no error detail"]);
        }

        NSData *out = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        fwrite(out.bytes, 1, out.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}
