#import <Foundation/Foundation.h>

// This helper is intentionally tiny and opt-in.  EventKit does not expose
// Reminders' native "Early Reminder" (due-date delta) field, so this file
// talks to ReminderKit only for that one field.  All other fields continue to
// be written by the public CalendarBridge EventKit process.

@interface REMObjectID : NSObject
+ (id)objectIDWithURL:(NSURL *)url;
- (NSUUID *)uuid;
@end

@interface REMStore : NSObject
- (id)fetchReminderWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchReminderWithObjectID:(id)objectID fetchOptions:(id)fetchOptions error:(NSError **)error;
@end

@interface REMReminderFetchOptions : NSObject
+ (instancetype)fetchOptionsIncludingDueDateDeltaAlerts;
@end

@interface REMSaveRequest : NSObject
- (instancetype)initWithStore:(REMStore *)store;
- (id)updateReminder:(id)reminder;
- (BOOL)saveSynchronouslyWithError:(NSError **)error;
@end

@interface REMReminderChangeItem : NSObject
- (id)dueDateDeltaAlertContext;
@end

@interface REMReminderDueDateDeltaAlertContextChangeItem : NSObject
- (id)addDueDateDeltaAlertWithDueDateDelta:(id)dueDateDelta;
- (void)removeAllFetchedDueDateDeltaAlerts;
- (void)removeDueDateDeltaAlertsWithIdentifiers:(NSArray *)identifiers;
@end

@interface REMDueDateDeltaInterval : NSObject
- (instancetype)initWithUnit:(NSInteger)unit count:(NSInteger)count;
@end

static void printJSON(NSDictionary *payload) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text) {
        fprintf(stdout, "%s\n", text.UTF8String);
    }
}

static int fail(NSString *message) {
    printJSON(@{ @"status": @"error", @"message": message ?: @"Unknown error" });
    return 1;
}

int main(void) {
    @autoreleasepool {
        NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        NSError *jsonError = nil;
        id object = [NSJSONSerialization JSONObjectWithData:input options:0 error:&jsonError];
        if (![object isKindOfClass:[NSDictionary class]]) {
            return fail(jsonError.localizedDescription ?: @"Expected a JSON object");
        }
        NSDictionary *command = object;
        NSString *action = command[@"action"];
        NSString *reminderID = command[@"id"];
        if ([action isEqualToString:@"probe"]) {
            BOOL available = [REMStore instancesRespondToSelector:@selector(fetchReminderWithObjectID:fetchOptions:error:)]
              && [REMReminderFetchOptions respondsToSelector:@selector(fetchOptionsIncludingDueDateDeltaAlerts)]
              && [REMSaveRequest instancesRespondToSelector:@selector(saveSynchronouslyWithError:)]
              && [REMReminderChangeItem instancesRespondToSelector:@selector(dueDateDeltaAlertContext)]
              && [NSClassFromString(@"REMReminderDueDateDeltaAlertContext") instancesRespondToSelector:NSSelectorFromString(@"fetchedCurrentDueDateDeltaAlert")]
              && [NSClassFromString(@"REMDueDateDeltaAlert") instancesRespondToSelector:NSSelectorFromString(@"dueDateDelta")]
              && [REMReminderDueDateDeltaAlertContextChangeItem instancesRespondToSelector:@selector(removeAllFetchedDueDateDeltaAlerts)]
              && [REMReminderDueDateDeltaAlertContextChangeItem instancesRespondToSelector:@selector(addDueDateDeltaAlertWithDueDateDelta:)];
            if (!available) return fail(@"Native Early Reminder API is incompatible; no reminder was changed");
            printJSON(@{ @"status": @"available", @"protocolVersion": @2 });
            return 0;
        }
        if (![action isKindOfClass:[NSString class]] || (![action isEqualToString:@"set_early_reminder"] && ![action isEqualToString:@"read_early_reminder"])) {
            return fail(@"Only action=set_early_reminder is supported");
        }
        if (![reminderID isKindOfClass:[NSString class]] || reminderID.length == 0) {
            return fail(@"id is required");
        }

        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
            @"x-apple-reminderkit://REMCDReminder/%@", reminderID]];
        id objectID = [REMObjectID objectIDWithURL:url];
        if (!objectID) return fail(@"Could not build ReminderKit reminder identifier");

        REMStore *store = [REMStore new];
        NSError *error = nil;
        id fetchOptions = [REMReminderFetchOptions fetchOptionsIncludingDueDateDeltaAlerts];
        id reminder = [store fetchReminderWithObjectID:objectID fetchOptions:fetchOptions error:&error];
        if (!reminder) return fail(error.localizedDescription ?: @"Reminder not found");

        if ([action isEqualToString:@"read_early_reminder"]) {
            @try {
                id context = [reminder valueForKey:@"dueDateDeltaAlertContext"];
                id alert = [context valueForKey:@"fetchedCurrentDueDateDeltaAlert"];
                if (!alert) { printJSON(@{ @"status": @"read", @"earlyReminder": [NSNull null] }); return 0; }
                id delta = [alert valueForKey:@"dueDateDelta"];
                NSNumber *unit = [delta valueForKey:@"unit"];
                NSNumber *count = [delta valueForKey:@"count"];
                if (![unit isKindOfClass:[NSNumber class]] || ![count isKindOfClass:[NSNumber class]]) return fail(@"Cannot read native Early Reminder");
                printJSON(@{ @"status": @"read", @"earlyReminder": @{ @"unit": unit, @"count": count } });
                return 0;
            } @catch (NSException *exception) { return fail(@"Native Early Reminder read API incompatible"); }
        }

        REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
        REMReminderChangeItem *change = [save updateReminder:reminder];
        if (!change) return fail(@"Could not create ReminderKit change item");
        REMReminderDueDateDeltaAlertContextChangeItem *context = [change dueDateDeltaAlertContext];
        if (!context) return fail(@"Reminder does not support Early Reminder changes");

        // Replacement semantics: one native Early Reminder is the value shown
        // by the iPhone Reminders detail screen.  Existing native alerts are
        // removed before the requested one is added.
        [context removeAllFetchedDueDateDeltaAlerts];

        NSNumber *clear = command[@"clear"];
        NSMutableDictionary *result = [@{
            @"status": @"updated",
            @"action": action,
            @"id": reminderID,
        } mutableCopy];
        if ([clear boolValue]) {
            result[@"earlyReminderCleared"] = @YES;
        } else {
            NSNumber *unitValue = command[@"unit"];
            NSNumber *countValue = command[@"count"];
            if (![unitValue isKindOfClass:[NSNumber class]] || ![countValue isKindOfClass:[NSNumber class]]) {
                return fail(@"unit and count are required unless clear=true");
            }
            NSInteger unit = unitValue.integerValue;
            NSInteger count = countValue.integerValue;
            if (unit < 0 || unit > 4) return fail(@"unit must be between 0 and 4");
            if (count == 0) return fail(@"count cannot be 0");
            REMDueDateDeltaInterval *delta = [[REMDueDateDeltaInterval alloc] initWithUnit:unit count:count];
            id alert = [context addDueDateDeltaAlertWithDueDateDelta:delta];
            if (!alert) return fail(@"Could not create Early Reminder delta alert");
            result[@"earlyReminder"] = @{ @"unit": @(unit), @"count": @(count) };
        }

        error = nil;
        if (![save saveSynchronouslyWithError:&error]) {
            return fail(error.localizedDescription ?: @"ReminderKit save failed");
        }
        printJSON(result);
        return 0;
    }
}
