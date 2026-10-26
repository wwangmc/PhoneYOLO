#import "../Sources/PYConfig.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <math.h>
#include <notify.h>

@interface PYSettings : UITableViewController <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSMutableDictionary *config;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UITextField *> *fields;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSTimer *timer;
@end
@implementation PYSettings
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"PhoneYOLO";
    self.config = [PYReadConfig() mutableCopy];
    self.fields = [NSMutableDictionary dictionary];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(save)];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1
                                                  target:self
                                                selector:@selector(refresh)
                                                userInfo:nil
                                                 repeats:YES];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}
- (void)message:(NSString *)title body:(NSString *)body {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:body
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)refresh {
    NSData *data =
        [NSData dataWithContentsOfFile:[PYDataDirectory() stringByAppendingPathComponent:@"status.json"]];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSDictionary *s = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
    NSString *error = [s[@"error"] isKindOfClass:NSString.class] ? s[@"error"] : @"";
    self.statusLabel.text =
        !s ? @"等待插件启动；安装后请重新启动 SpringBoard"
        : error.length
            ? error
            : [NSString stringWithFormat:@"%@ · %lu 个连接 · 已推送 %@ 帧",
                                         [s[@"enabled"] boolValue]
                                             ? ([s[@"detecting"] boolValue] ? @"检测中" : @"等待连接")
                                             : @"服务已停止",
                                         (unsigned long)[s[@"clients"] unsignedIntegerValue],
                                         s[@"sequence"] ?: @0];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 4;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 2 : section == 1 ? 3 : section == 2 ? 5 : 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return @[ @"运行状态", @"检测模型", @"检测参数", @"连接" ][(NSUInteger)section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    return section == 0
               ? @"只有通过 token 认证的 WebSocket "
                 @"连接才会启动截屏和推理；全部断开后自动释放模型。保存会断开现有连接，客户端需重连。"
           : section == 1 ? @"内置 YOLOv8n COCO 模型识别人、车辆、动物等 80 类物体。自定义 UI / "
                            @"游戏目标需要另行训练。导入模型请使用项目导出脚本。"
           : section == 2
               ? @"1–30 FPS 为目标上限；实际速度取决于设备和模型。坐标为当前屏幕方向下、左上角原点的像素。"
               : @"点击复制局域网连接地址。token 是访问凭证；请只在可信网络使用。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (index.section == 0 && index.row == 0) {
        cell.textLabel.text = @"启用 WebSocket 服务";
        UISwitch *toggle = [UISwitch new];
        toggle.on = [self.config[@"enabled"] boolValue];
        [toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (index.section == 0) {
        self.statusLabel = cell.textLabel;
        self.statusLabel.numberOfLines = 0;
        self.statusLabel.font = [UIFont systemFontOfSize:13];
        [self refresh];
    } else if (index.section == 1) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.text =
            @[ @"导入自训练模型", @"使用内置 YOLOv8n", @"打开测试画面" ][(NSUInteger)index.row];
        if (index.row == 0) {
            cell.detailTextLabel.text = [self.config[@"modelPath"] lastPathComponent];
            cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        }
    } else if (index.section == 2) {
        NSArray *keys = @[ @"port", @"fps", @"confidence", @"iou", @"maxDetections" ];
        NSString *key = keys[(NSUInteger)index.row];
        cell.textLabel.text =
            @[ @"端口", @"目标 FPS", @"置信度阈值", @"NMS IoU 阈值", @"最多检测数量" ][(NSUInteger)index.row];
        UITextField *field = self.fields[key];
        if (!field) {
            field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 100, 36)];
            field.text = [self.config[key] description];
            field.textAlignment = NSTextAlignmentRight;
            field.keyboardType = UIKeyboardTypeDecimalPad;
            self.fields[key] = field;
        }
        cell.accessoryView = field;
    } else {
        cell.textLabel.text = index.row == 0 ? @"复制 WebSocket 地址" : @"更换访问 token";
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (index.row == 0)
            cell.detailTextLabel.text = @"ws://设备IP:端口/detections?token=…";
    }
    return cell;
}
- (void)toggle:(UISwitch *)toggle {
    NSMutableDictionary *next = [PYReadConfig() mutableCopy];
    next[@"enabled"] = @(toggle.on);
    NSError *error = nil;
    if (!PYWriteConfig(next, &error)) {
        toggle.on = !toggle.on;
        [self message:@"保存失败" body:error.localizedDescription];
        return;
    }
    self.config[@"enabled"] = next[@"enabled"];
    notify_post(PYConfigNotification);
}
- (BOOL)save {
    [self.view endEditing:YES];
    NSDictionary *ranges = @{
        @"port" : @[ @1024, @65535 ],
        @"fps" : @[ @1, @30 ],
        @"confidence" : @[ @0.01, @1 ],
        @"iou" : @[ @0.01, @1 ],
        @"maxDetections" : @[ @1, @300 ]
    };
    NSMutableDictionary *next = [self.config mutableCopy];
    for (NSString *key in self.fields) {
        NSString *text = self.fields[key].text;
        NSScanner *scanner = [NSScanner scannerWithString:text];
        double value = 0;
        if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value) ||
            value < [ranges[key][0] doubleValue] || value > [ranges[key][1] doubleValue] ||
            (([key isEqual:@"port"] || [key isEqual:@"maxDetections"]) && floor(value) != value)) {
            [self
                message:@"参数无效"
                   body:[NSString stringWithFormat:@"%@ 范围是 %@–%@", key, ranges[key][0], ranges[key][1]]];
            return NO;
        }
        next[key] = @(value);
    }
    NSError *error = nil;
    if (!PYWriteConfig(next, &error)) {
        [self message:@"保存失败" body:error.localizedDescription];
        return NO;
    }
    self.config = next;
    notify_post(PYConfigNotification);
    return YES;
}
- (NSString *)address {
    NSString *host = @"127.0.0.1";
    struct ifaddrs *addresses = NULL;
    if (!getifaddrs(&addresses)) {
        for (struct ifaddrs *p = addresses; p; p = p->ifa_next) {
            if (p->ifa_addr && p->ifa_addr->sa_family == AF_INET && !strcmp(p->ifa_name, "en0")) {
                char ip[INET_ADDRSTRLEN];
                inet_ntop(AF_INET, &((struct sockaddr_in *)p->ifa_addr)->sin_addr, ip, sizeof(ip));
                host = [NSString stringWithUTF8String:ip];
                break;
            }
        }
        freeifaddrs(addresses);
    }
    return [NSString stringWithFormat:@"ws://%@:%@/detections?token=%@", host, self.config[@"port"],
                                      self.config[@"token"]];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {
    [tableView deselectRowAtIndexPath:index animated:YES];
    if (index.section == 1 && index.row == 0) {
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeData, UTTypeFolder ]
                                                                        asCopy:NO];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    } else if (index.section == 1 && index.row == 1) {
        self.config[@"modelPath"] = PYBundledModel();
        [self save];
        [self.tableView reloadData];
    } else if (index.section == 1 && index.row == 2) {
        UIViewController *test = [UIViewController new];
        test.title = @"YOLOv8n 测试画面";
        test.view.backgroundColor = UIColor.systemBackgroundColor;
        NSString *path =
            [PYBundledModel().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"bus.jpg"];
        UIImageView *image = [[UIImageView alloc] initWithImage:[UIImage imageWithContentsOfFile:path]];
        image.contentMode = UIViewContentModeScaleAspectFit;
        image.translatesAutoresizingMaskIntoConstraints = NO;
        [test.view addSubview:image];
        [NSLayoutConstraint activateConstraints:@[
            [image.topAnchor constraintEqualToAnchor:test.view.safeAreaLayoutGuide.topAnchor],
            [image.bottomAnchor constraintEqualToAnchor:test.view.safeAreaLayoutGuide.bottomAnchor],
            [image.leadingAnchor constraintEqualToAnchor:test.view.leadingAnchor],
            [image.trailingAnchor constraintEqualToAnchor:test.view.trailingAnchor]
        ]];
        [self.navigationController pushViewController:test animated:YES];
    } else if (index.section == 3 && index.row == 0) {
        UIPasteboard.generalPasteboard.string = [self address];
        [self message:@"地址已复制" body:[self address]];
    } else if (index.section == 3 && index.row == 1) {
        self.config[@"token"] = [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-"
                                                                                  withString:@""];
        if ([self save])
            [self message:@"token 已更换" body:@"请复制新地址供客户端重新连接。"];
    }
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *source = urls.firstObject;
    if (!source)
        return;
    if (![@[ @"mlmodel", @"mlmodelc" ] containsObject:source.pathExtension.lowercaseString]) {
        [self message:@"格式不支持"
                 body:@"请选择 .mlmodel 或 .mlmodelc；.pt 请先使用项目脚本转换。为兼容 iOS 14，使用 "
                      @"NeuralNetwork 格式。"];
        return;
    }
    BOOL scoped = [source startAccessingSecurityScopedResource];
    NSError *error = nil;
    NSString *directory = [PYDataDirectory() stringByAppendingPathComponent:@"Models"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&error];
    NSString *name = [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, source.lastPathComponent];
    NSString *destination = [directory stringByAppendingPathComponent:name];
    BOOL copied = !error && [NSFileManager.defaultManager copyItemAtURL:source
                                                                  toURL:[NSURL fileURLWithPath:destination]
                                                                  error:&error];
    if (scoped)
        [source stopAccessingSecurityScopedResource];
    if (!copied) {
        [self message:@"导入失败" body:error.localizedDescription];
        return;
    }
    self.config[@"modelPath"] = destination;
    [self save];
    [self.tableView reloadData];
}
@end

@interface PYAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation PYAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc]
        initWithRootViewController:[[PYSettings alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
