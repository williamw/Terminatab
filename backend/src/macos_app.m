#import <Cocoa/Cocoa.h>
#include <unistd.h>

extern void terminatab_server_start(void);

static NSImage *createMenuBarIcon(void) {
    // Draw ">_" programmatically as a template image (18x18 @2x)
    NSSize size = NSMakeSize(18, 18);
    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor blackColor],
    };
    NSString *text = @">_";
    NSSize textSize = [text sizeWithAttributes:attrs];
    NSPoint point = NSMakePoint(
        (size.width - textSize.width) / 2,
        (size.height - textSize.height) / 2
    );
    [text drawAtPoint:point withAttributes:attrs];

    [image unlockFocus];
    [image setTemplate:YES];
    return image;
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = createMenuBarIcon();

    // Create dropdown menu
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *titleItem = [menu addItemWithTitle:@"Terminatab Running"
                                            action:nil
                                     keyEquivalent:@""];
    [titleItem setEnabled:NO];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit Terminatab"
                    action:@selector(terminate:)
             keyEquivalent:@"q"];
    self.statusItem.menu = menu;

    // Start WebSocket server on background thread
    dispatch_async(
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            terminatab_server_start();
        });
}

@end

void macos_app_main(void) {
    // Daemonize: fork so the shell returns immediately
    pid_t pid = fork();
    if (pid < 0) {
        return;
    }
    if (pid > 0) {
        _exit(0); // parent exits, returning control to shell
    }

    // Child: new session, detach from terminal
    setsid();
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        dup2(devnull, STDIN_FILENO);
        dup2(devnull, STDOUT_FILENO);
        dup2(devnull, STDERR_FILENO);
        if (devnull > STDERR_FILENO) close(devnull);
    }

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
}
