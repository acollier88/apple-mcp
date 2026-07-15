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
// Read-only (IDEAS #47) — parent lookup, exclusive of the ops above:
//     {"parentsOf": ["<ext1>", "<ext2>", ...]}
//   -> {"ok":true,"parents":{"<ext1>":"<parentExt>"|null, ...}} (null = top-level;
//      ids that fail to fetch are omitted)
// Read-only (IDEAS #46) — attachment listing, exclusive:
//     {"attachmentsOf": ["<ext1>", ...]}
//   -> {"ok":true,"attachments":{"<ext1>":[{"kind":"file|image|url",
//      "uti":..., "fileURL":..., "fileSize":N, "url":...}, ...], ...}}
// Write (IDEAS #46) — attach to a reminder (combines with tags/parent ops):
//     {"externalId": "<ext>", "attachFile": "/abs/path"}
//     {"externalId": "<ext>", "attachURL": "https://..."}
// Success: {"ok":true,"tagged":N,"parent":"set|cleared"} on stdout (fields
// present only for operations performed). Failure: {"error":"..."} on stderr, exit 1.
//
// Tag removal is intentionally absent: ReminderKit's hashtag change context
// only exposes addHashtagWithType:name:. The [tag] title prefix remains the
// source of truth; this mirror is additive only. Sections are not yet
// mirrored (the reminder->section reference is unproven); subtasks are.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
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

@interface REMReminder : NSObject
- (id)parentReminderID; // REMObjectID, readonly (probed 2026-07-15)
@end

@interface REMObjectIDReadable : NSObject
- (NSUUID *)uuid;
@end

@interface REMReminderHashtagContextChangeItem : NSObject
- (id)addHashtagWithType:(NSInteger)type name:(NSString *)name;
@end

@interface REMReminderSubtaskContextChangeItem : NSObject
- (void)addReminderChangeItem:(id)changeItem;
@end

@interface REMReminderAttachmentContextChangeItem : NSObject
- (id)addFileAttachmentWithURL:(NSURL *)url error:(NSError **)error;
- (id)addURLAttachmentWithURL:(NSURL *)url;
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
            // Read side (IDEAS #47): parent lookup for dependency gating.
            // parentReminderID is @dynamic, so probe the property table —
            // instancesRespondToSelector is false before runtime resolution.
            Class reminderClass = NSClassFromString(@"REMReminder");
            BOOL subtaskRead = reminderClass
                && class_getProperty(reminderClass, "parentReminderID") != NULL;
            printf("{\"ok\":true,\"mode\":\"check\",\"subtasks\":%s,\"subtaskRead\":%s}\n",
                   subtasks ? "true" : "false", subtaskRead ? "true" : "false");
            return 0;
        }

        NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        NSError *error = nil;
        NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:input options:0 error:&error];
        if (![cmd isKindOfClass:[NSDictionary class]]) failJSON(@"stdin must be a JSON object");

        // Read-only parent lookup (IDEAS #47): exclusive op, exits here.
        NSArray *parentsOf = cmd[@"parentsOf"];
        if ([parentsOf isKindOfClass:[NSArray class]]) {
            Class objectIDClass = requireClass(@"REMObjectID");
            Class storeClass = requireClass(@"REMStore");
            if (![objectIDClass respondsToSelector:@selector(objectIDWithURL:)]) failJSON(@"REMObjectID.objectIDWithURL: missing");
            REMStore *store = (REMStore *)[storeClass new];
            if (![store respondsToSelector:@selector(fetchReminderWithObjectID:error:)]) failJSON(@"REMStore.fetchReminderWithObjectID:error: missing");

            NSMutableDictionary *parents = [NSMutableDictionary dictionary];
            for (id ext in parentsOf) {
                if (![ext isKindOfClass:[NSString class]] || [ext length] == 0) continue;
                NSString *urlString = [NSString stringWithFormat:@"x-apple-reminderkit://REMCDReminder/%@", ext];
                id oid = [(Class)objectIDClass objectIDWithURL:[NSURL URLWithString:urlString]];
                if (!oid) continue;
                NSError *fetchError = nil;
                REMReminder *reminder = [store fetchReminderWithObjectID:oid error:&fetchError];
                if (!reminder) continue; // omitted = unknown to ReminderKit
                // parentReminderID is @dynamic — go through KVC, which
                // resolves dynamic accessors; a missing key means the read
                // API changed on this macOS.
                id parentID = nil;
                @try {
                    parentID = [reminder valueForKey:@"parentReminderID"];
                } @catch (NSException *e) {
                    failJSON(@"REMReminder.parentReminderID missing (subtask read API changed)");
                }
                if (parentID && [parentID respondsToSelector:@selector(uuid)]) {
                    parents[ext] = [[(REMObjectIDReadable *)parentID uuid] UUIDString] ?: (id)[NSNull null];
                } else {
                    parents[ext] = [NSNull null];
                }
            }
            NSDictionary *result = @{ @"ok": @YES, @"parents": parents };
            NSData *out = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            fwrite(out.bytes, 1, out.length, stdout);
            fputc('\n', stdout);
            return 0;
        }

        // Read-only attachment listing (IDEAS #46): exclusive op, exits here.
        NSArray *attachmentsOf = cmd[@"attachmentsOf"];
        if ([attachmentsOf isKindOfClass:[NSArray class]]) {
            Class objectIDClass = requireClass(@"REMObjectID");
            Class storeClass = requireClass(@"REMStore");
            if (![objectIDClass respondsToSelector:@selector(objectIDWithURL:)]) failJSON(@"REMObjectID.objectIDWithURL: missing");
            REMStore *store = (REMStore *)[storeClass new];
            if (![store respondsToSelector:@selector(fetchReminderWithObjectID:error:)]) failJSON(@"REMStore.fetchReminderWithObjectID:error: missing");
            Class imageClass = NSClassFromString(@"REMImageAttachment");
            Class fileClass = NSClassFromString(@"REMFileAttachment");
            Class urlClass = NSClassFromString(@"REMURLAttachment");

            NSMutableDictionary *byId = [NSMutableDictionary dictionary];
            for (id ext in attachmentsOf) {
                if (![ext isKindOfClass:[NSString class]] || [ext length] == 0) continue;
                NSString *urlString = [NSString stringWithFormat:@"x-apple-reminderkit://REMCDReminder/%@", ext];
                id oid = [(Class)objectIDClass objectIDWithURL:[NSURL URLWithString:urlString]];
                if (!oid) continue;
                NSError *fetchError = nil;
                REMReminder *reminder = [store fetchReminderWithObjectID:oid error:&fetchError];
                if (!reminder) continue;
                NSArray *attachments = nil;
                @try {
                    attachments = [(id)reminder valueForKey:@"attachments"]; // @dynamic — via KVC
                } @catch (NSException *e) {
                    failJSON(@"REMReminder.attachments missing (attachment read API changed)");
                }
                NSMutableArray *rows = [NSMutableArray array];
                for (id att in attachments) {
                    NSMutableDictionary *row = [NSMutableDictionary dictionary];
                    if (imageClass && [att isKindOfClass:imageClass]) row[@"kind"] = @"image";
                    else if (fileClass && [att isKindOfClass:fileClass]) row[@"kind"] = @"file";
                    else if (urlClass && [att isKindOfClass:urlClass]) row[@"kind"] = @"url";
                    else row[@"kind"] = @"other";
                    @try {
                        id uti = [att valueForKey:@"uti"];
                        if ([uti isKindOfClass:[NSString class]]) row[@"uti"] = uti;
                    } @catch (NSException *e) {}
                    if (fileClass && [att isKindOfClass:fileClass]) {
                        @try {
                            NSURL *fileURL = [att valueForKey:@"fileURL"];
                            if ([fileURL isKindOfClass:[NSURL class]]) row[@"fileURL"] = fileURL.path ?: fileURL.absoluteString;
                            id size = [att valueForKey:@"fileSize"];
                            if (size) row[@"fileSize"] = size;
                        } @catch (NSException *e) {}
                    }
                    if (urlClass && [att isKindOfClass:urlClass]) {
                        @try {
                            NSURL *url = [att valueForKey:@"url"];
                            if ([url isKindOfClass:[NSURL class]]) row[@"url"] = url.absoluteString;
                        } @catch (NSException *e) {}
                    }
                    [rows addObject:row];
                }
                byId[ext] = rows;
            }
            NSDictionary *result = @{ @"ok": @YES, @"attachments": byId };
            NSData *out = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            fwrite(out.bytes, 1, out.length, stdout);
            fputc('\n', stdout);
            return 0;
        }

        NSString *externalId = cmd[@"externalId"];
        NSArray *tags = cmd[@"tags"];
        NSString *parentId = cmd[@"parent"];
        BOOL clearParent = [cmd[@"clearParent"] boolValue];
        NSString *attachFile = cmd[@"attachFile"];
        NSString *attachURL = cmd[@"attachURL"];
        if (![externalId isKindOfClass:[NSString class]] || externalId.length == 0) failJSON(@"missing externalId");
        BOOL wantTags = [tags isKindOfClass:[NSArray class]] && tags.count > 0;
        BOOL wantParent = [parentId isKindOfClass:[NSString class]] && parentId.length > 0;
        BOOL wantAttachFile = [attachFile isKindOfClass:[NSString class]] && attachFile.length > 0;
        BOOL wantAttachURL = [attachURL isKindOfClass:[NSString class]] && attachURL.length > 0;
        if (!wantTags && !wantParent && !clearParent && !wantAttachFile && !wantAttachURL)
            failJSON(@"nothing to do (need tags, parent, clearParent, attachFile, or attachURL)");

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

        if (wantAttachFile || wantAttachURL) {
            id attachmentContext = nil;
            @try {
                attachmentContext = [(id)change valueForKey:@"attachmentContext"];
            } @catch (NSException *e) {}
            if (!attachmentContext) failJSON(@"attachmentContext missing (attachment API changed)");
            if (wantAttachFile) {
                if (![attachmentContext respondsToSelector:@selector(addFileAttachmentWithURL:error:)]) failJSON(@"addFileAttachmentWithURL:error: missing");
                NSURL *fileURL = [NSURL fileURLWithPath:attachFile];
                NSError *attachError = nil;
                if (![(REMReminderAttachmentContextChangeItem *)attachmentContext addFileAttachmentWithURL:fileURL error:&attachError]) {
                    failJSON([NSString stringWithFormat:@"attachFile failed: %@",
                              attachError.localizedDescription ?: @"no error detail"]);
                }
                result[@"attached"] = @"file";
            }
            if (wantAttachURL) {
                if (![attachmentContext respondsToSelector:@selector(addURLAttachmentWithURL:)]) failJSON(@"addURLAttachmentWithURL: missing");
                NSURL *url = [NSURL URLWithString:attachURL];
                if (!url) failJSON(@"attachURL is not a valid URL");
                [(REMReminderAttachmentContextChangeItem *)attachmentContext addURLAttachmentWithURL:url];
                result[@"attached"] = wantAttachFile ? @"file+url" : @"url";
            }
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
