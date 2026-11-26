#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <signal.h>
@interface AODSecondsRootListController : PSListController
@end
@implementation AODSecondsRootListController
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *prefs=[NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/AODSeconds-settings.plist"];
    return prefs[@"Enabled"] ?: @YES;
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [@{@"Enabled":@([value boolValue])} writeToFile:@"/var/mobile/Media/AODSeconds-settings.plist" atomically:YES];
}
- (void)respring {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"AODSeconds" message:@"Apply settings and restart SpringBoard?" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        pid_t pid=0;
        const char *tool="/usr/bin/killall";
        char *const args[]={(char *)tool,(char *)"-TERM",(char *)"SpringBoard",NULL};
        extern char **environ;
        if(posix_spawn(&pid,tool,NULL,NULL,args,environ)!=0) {
            UIAlertController *error=[UIAlertController alertControllerWithTitle:@"AODSeconds" message:@"Please respring using your jailbreak app." preferredStyle:UIAlertControllerStyleAlert];
            [error addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:error animated:YES completion:nil];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
