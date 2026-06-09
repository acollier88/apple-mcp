// apple-tasks-private: write-only native Reminders tag mirror.
//
// Uses Apple's PRIVATE ReminderKit framework (unsupported; may break on any
// macOS update). Loaded via dlopen + NSClassFromString so this binary builds
// and runs even if the framework changes — every class and selector is probed
// before use and failures come back as clean JSON errors.
//
// Protocol: one JSON object on stdin:
//   {"externalId": "<EKReminder.calendarItemExternalIdentifier>", "tags": ["a","b"]}
// Success: {"ok":true,"tagged":N} on stdout. Failure: {"error":"..."} on stderr, exit 1.
//
// Tag removal is intentionally absent: ReminderKit's hashtag change context
// only exposes addHashtagWithType:name:. The [tag] title prefix remains the
// source of truth; this mirror is additive only.

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
@end

@interface REMReminderHashtagContextChangeItem : NSObject
- (id)addHashtagWithType:(NSInteger)type name:(NSString *)name;
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
            puts("{\"ok\":true,\"mode\":\"check\"}");
            return 0;
        }

        NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        NSError *error = nil;
        NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:input options:0 error:&error];
        if (![cmd isKindOfClass:[NSDictionary class]]) failJSON(@"stdin must be a JSON object");

        NSString *externalId = cmd[@"externalId"];
        NSArray *tags = cmd[@"tags"];
        if (![externalId isKindOfClass:[NSString class]] || externalId.length == 0) failJSON(@"missing externalId");
        if (![tags isKindOfClass:[NSArray class]] || tags.count == 0) failJSON(@"missing tags");

        Class objectIDClass = requireClass(@"REMObjectID");
        Class storeClass = requireClass(@"REMStore");
        Class saveClass = requireClass(@"REMSaveRequest");
        if (![objectIDClass respondsToSelector:@selector(objectIDWithURL:)]) failJSON(@"REMObjectID.objectIDWithURL: missing");

        NSString *urlString = [NSString stringWithFormat:@"x-apple-reminderkit://REMCDReminder/%@", externalId];
        id objectID = [(Class)objectIDClass objectIDWithURL:[NSURL URLWithString:urlString]];
        if (!objectID) failJSON(@"could not build ReminderKit object ID");

        REMStore *store = (REMStore *)[storeClass new];
        if (![store respondsToSelector:@selector(fetchReminderWithObjectID:error:)]) failJSON(@"REMStore.fetchReminderWithObjectID:error: missing");
        id reminder = [store fetchReminderWithObjectID:objectID error:&error];
        if (!reminder) {
            failJSON([NSString stringWithFormat:@"reminder not found for externalId %@: %@",
                      externalId, error.localizedDescription ?: @"no error detail"]);
        }

        REMSaveRequest *save = [(REMSaveRequest *)[saveClass alloc] initWithStore:store];
        if (![save respondsToSelector:@selector(updateReminder:)]) failJSON(@"REMSaveRequest.updateReminder: missing");
        REMReminderChangeItem *change = [save updateReminder:reminder];
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

        if (![save saveSynchronouslyWithError:&error]) {
            failJSON([NSString stringWithFormat:@"ReminderKit save failed: %@",
                      error.localizedDescription ?: @"no error detail"]);
        }

        NSDictionary *result = @{ @"ok": @YES, @"tagged": @(tagged) };
        NSData *out = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        fwrite(out.bytes, 1, out.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}
