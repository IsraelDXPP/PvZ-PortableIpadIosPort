#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

void iOSUncaughtExceptionHandler(NSException *exception) {
    NSArray *arr = [exception callStackSymbols];
    NSString *reason = [exception reason];
    NSString *name = [exception name];
    NSString *crashLog = [NSString stringWithFormat:@"Exception: %@\nReason: %@\nStack: %@", name, reason, arr];
    
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *logPath = [docPath stringByAppendingPathComponent:@"crash_exception.txt"];
    [crashLog writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Try to show an alert to the user before the app terminates
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Fatal NSException"
                                                        message:reason
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
        [alert show];
    });
}

extern "C" void install_ios_exception_handler() {
    NSSetUncaughtExceptionHandler(&iOSUncaughtExceptionHandler);
}
