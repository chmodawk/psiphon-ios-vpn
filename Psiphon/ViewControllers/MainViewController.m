/*
 * Copyright (c) 2017, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import <Foundation/Foundation.h>
#import <PsiphonTunnel/PsiphonTunnel.h>
#import "MainViewController.h"
#import "AdManager.h"
#import "AppInfo.h"
#import "AppDelegate.h"
#import "Asserts.h"
#import "AvailableServerRegions.h"
#import "DispatchUtils.h"
#import "FeedbackManager.h"
#import "IAPViewController.h"
#import "Logging.h"
#import "DebugViewController.h"
#import "PsiphonConfigUserDefaults.h"
#import "SharedConstants.h"
#import "NSString+Additions.h"
#import "UIAlertController+Additions.h"
#import "UpstreamProxySettings.h"
#import "RACCompoundDisposable.h"
#import "RACTuple.h"
#import "RACReplaySubject.h"
#import "RACSignal+Operations.h"
#import "RACUnit.h"
#import "RegionSelectionButton.h"
#import "PsiCashBalanceView.h"
#import "PsiCashClient.h"
#import "PsiCashSpeedBoostMeterView.h"
#import "PsiCashView.h"
#import "SubscriptionsBar.h"
#import "UIColor+Additions.h"
#import "UIFont+Additions.h"
#import "UILabel+GetLabelHeight.h"
#import "VPNManager.h"
#import "VPNStartAndStopButton.h"
#import "AlertDialogs.h"
#import "RACSignal+Operations2.h"
#import "ContainerDB.h"
#import "NSDate+Comparator.h"
#import "PickerViewController.h"
#import "Strings.h"
#import "SkyRegionSelectionViewController.h"
#import "UIView+Additions.h"


PsiFeedbackLogType const MainViewControllerLogType = @"MainViewController";
PsiFeedbackLogType const RewardedVideoLogType = @"RewardedVideo";

UserDefaultsKey const PsiCashHasBeenOnboardedBoolKey = @"PsiCash.HasBeenOnboarded";

#if DEBUG
NSTimeInterval const MaxAdLoadingTime = 1.f;
#else
NSTimeInterval const MaxAdLoadingTime = 10.f;
#endif

// TODO: turn this into an enum.
NSString * const CommandNoInternetAlert = @"NoInternetAlert";
NSString * const CommandStartTunnel = @"StartTunnel";
NSString * const CommandStopVPN = @"StopVPN";


@interface MainViewController ()

@property (nonatomic) RACCompoundDisposable *compoundDisposable;
@property (nonatomic) AdManager *adManager;
@property (nonatomic) VPNManager *vpnManager;

@property (nonatomic, readonly) BOOL startVPNOnFirstLoad;

@end

@implementation MainViewController {
    // Models
    AvailableServerRegions *availableServerRegions;

    // UI elements
    UILabel *statusLabel;
    UIButton *versionLabel;
    SubscriptionsBar *subscriptionsBar;
    RegionSelectionButton *regionSelectionButton;
    VPNStartAndStopButton *startAndStopButton;
    
    // UI Constraint
    NSLayoutConstraint *startButtonWidth;
    NSLayoutConstraint *startButtonHeight;
    
    // Settings
    PsiphonSettingsViewController *appSettingsViewController;
    UIButton *settingsButton;
    
    // Region Selection
    UIView *bottomBar;
    CAGradientLayer *bottomBarGradient;

    FeedbackManager *feedbackManager;

    // Psiphon Logo
    // Replaces the PsiCash UI when the user is subscribed
    UIImageView *psiphonSmallLogo;
    UIImageView *psiphonLargeLogo;

    // PsiCash
    RACBehaviorSubject<NSNumber*> *psiCashOnboardingCompleted;
    NSLayoutConstraint *psiCashViewHeight;
    PsiCashPurchaseAlertView *alertView;
    PsiCashClientModel *model;
    PsiCashView *psiCashView;

    // Clouds
    UIImageView *cloudMiddleLeft;
    UIImageView *cloudMiddleRight;
    UIImageView *cloudTopRight;
    UIImageView *cloudBottomRight;
    NSLayoutConstraint *cloudMiddleLeftHorizontalConstraint;
    NSLayoutConstraint *cloudMiddleRightHorizontalConstraint;
    NSLayoutConstraint *cloudTopRightHorizontalConstraint;
    NSLayoutConstraint *cloudBottomRightHorizontalConstraint;
}

// Force portrait orientation
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return (UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskPortraitUpsideDown);
}

// No heavy initialization should be done here, since RootContainerController
// expects this method to return immediately.
// All such initialization could be deferred to viewDidLoad callback.
- (id)initWithStartingVPN:(BOOL)startVPN {
    self = [super init];
    if (self) {
        
        _compoundDisposable = [RACCompoundDisposable compoundDisposable];
        
        _vpnManager = [VPNManager sharedInstance];
        
        _adManager = [AdManager sharedInstance];
        
        feedbackManager = [[FeedbackManager alloc] init];

        // TODO: remove persistance form init function.
        [self persistSettingsToSharedUserDefaults];
        
        _openSettingImmediatelyOnViewDidAppear = FALSE;

        _startVPNOnFirstLoad = startVPN;

        [RegionAdapter sharedInstance].delegate = self;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.compoundDisposable dispose];
}

#pragma mark - Lifecycle methods
- (void)viewDidLoad {
    LOG_DEBUG();
    [super viewDidLoad];

    // Check privacy policy accepted date.
    {
        // `[ContainerDB privacyPolicyLastUpdateTime]` should be equal to `[ContainerDB lastAcceptedPrivacyPolicy]`.
        // Log error if this is not the case.
        ContainerDB *containerDB = [[ContainerDB alloc] init];

        if (![containerDB hasAcceptedLatestPrivacyPolicy]) {
            NSDictionary *jsonDescription = @{@"event": @"PrivacyPolicyDateMismatch",
              @"got": [PsiFeedbackLogger safeValue:[containerDB lastAcceptedPrivacyPolicy]],
              @"expected": [containerDB privacyPolicyLastUpdateTime]};

            [PsiFeedbackLogger errorWithType:MainViewControllerLogType json:jsonDescription];
        }
    }

    availableServerRegions = [[AvailableServerRegions alloc] init];
    [availableServerRegions sync];

    psiCashOnboardingCompleted = [[RACBehaviorSubject alloc] init];
    BOOL onboarded = [[NSUserDefaults standardUserDefaults] boolForKey:PsiCashHasBeenOnboardedBoolKey];
    [psiCashOnboardingCompleted sendNext:[NSNumber numberWithBool:onboarded]];
    
    // Setting up the UI
    // calls them in the right order
    [self.view setBackgroundColor:UIColor.darkBlueColor];
    [self setNeedsStatusBarAppearanceUpdate];
    [self addViews];

    [self setupClouds];
    [self setupSmallPsiphonLogoAndVersionLabel];
    [self setupSettingsButton];
    [self setupPsiphonLogoView];
    [self setupPsiCashView];
    [self setupStartAndStopButton];
    [self setupStatusLabel];
    [self setupRegionSelectionButton];
    [self setupBottomBar];
    [self setupAddSubscriptionsBar];

    MainViewController *__weak weakSelf = self;
    
    // Observe VPN status for updating UI state
    RACDisposable *tunnelStatusDisposable = [[self.vpnManager.lastTunnelStatus distinctUntilChanged]
      subscribeNext:^(NSNumber *statusObject) {
          MainViewController *__strong strongSelf = weakSelf;
          if (strongSelf != nil) {

              VPNStatus s = (VPNStatus) [statusObject integerValue];


              [weakSelf updateUIConnectionState:s];

              // Notify SettingsViewController that the state has changed.
              // Note that this constant is used PsiphonClientCommonLibrary, and cannot simply be replaced by a RACSignal.
              // TODO: replace this notification with the appropriate signal.
              [[NSNotificationCenter defaultCenter] postNotificationName:kPsiphonConnectionStateNotification object:nil];
          }
      }];
    
    [self.compoundDisposable addDisposable:tunnelStatusDisposable];
    
    RACDisposable *vpnStartStatusDisposable = [[self.vpnManager.vpnStartStatus
      deliverOnMainThread]
      subscribeNext:^(NSNumber *statusObject) {
          MainViewController *__strong strongSelf = weakSelf;
          if (strongSelf != nil) {

              VPNStartStatus startStatus = (VPNStartStatus) [statusObject integerValue];

              if (startStatus == VPNStartStatusStart) {
                  [strongSelf->startAndStopButton setHighlighted:TRUE];
              } else {
                  [strongSelf->startAndStopButton setHighlighted:FALSE];
              }

              if (startStatus == VPNStartStatusFailedUserPermissionDenied) {

                  // Present the VPN permission denied alert.
                  UIAlertController *alert = [AlertDialogs vpnPermissionDeniedAlert];
                  [alert presentFromTopController];

              } else if (startStatus == VPNStartStatusFailedOther) {

                  // Alert the user that the VPN failed to start, and that they should try again.
                  [UIAlertController presentSimpleAlertWithTitle:NSLocalizedStringWithDefaultValue(@"VPN_START_FAIL_TITLE", nil, [NSBundle mainBundle], @"Unable to start", @"Alert dialog title indicating to the user that Psiphon was unable to start (MainViewController)")
                                                         message:NSLocalizedStringWithDefaultValue(@"VPN_START_FAIL_MESSAGE", nil, [NSBundle mainBundle], @"An error occurred while starting Psiphon. Please try again. If this problem persists, try reinstalling the Psiphon app.", @"Alert dialog message informing the user that an error occurred while starting Psiphon (Do not translate 'Psiphon'). The user should try again, and if the problem persists, they should try reinstalling the app.")
                                                  preferredStyle:UIAlertControllerStyleAlert
                                                       okHandler:nil];
              }
          }
      }];
    
    [self.compoundDisposable addDisposable:vpnStartStatusDisposable];


    // Subscribes to AppDelegate subscription signal.
    __block RACDisposable *disposable = [[AppDelegate sharedAppDelegate].subscriptionStatus
      subscribeNext:^(NSNumber *value) {
          MainViewController *__strong strongSelf = weakSelf;
          if (strongSelf != nil) {
              UserSubscriptionStatus s = (UserSubscriptionStatus) [value integerValue];

              if (s == UserSubscriptionUnknown) {
                  return;
              }

              [strongSelf->subscriptionsBar subscriptionActive:(s == UserSubscriptionActive)];

              BOOL showPsiCashUI = (s == UserSubscriptionInactive);
              [strongSelf setPsiCashContentHidden:!showPsiCashUI];
          }
      } error:^(NSError *error) {
          [weakSelf.compoundDisposable removeDisposable:disposable];
      } completed:^{
          [weakSelf.compoundDisposable removeDisposable:disposable];
      }];

    [self.compoundDisposable addDisposable:disposable];

    // If MainViewController is asked to start VPN first, then initialize dependencies
    // only after starting the VPN. Otherwise, we initialize the dependencies immediately.
    {
        __block RACDisposable *startDisposable = [[[[RACSignal return:@(self.startVPNOnFirstLoad)]
          flattenMap:^RACSignal<RACUnit *> *(NSNumber *startVPNFirst) {

              if ([startVPNFirst boolValue]) {
                  return [[weakSelf startOrStopVPNSignalWithAd:FALSE]
                    mapReplace:RACUnit.defaultUnit];
              } else {
                  return [RACSignal return:RACUnit.defaultUnit];
              }
          }]
          doNext:^(RACUnit *x) {
              // Start PsiCash and AdManager lifecycle.
              // Important: dependencies might be initialized while the tunnel is connecting or
              // when there is no active internet connection.

              // TODO: Add custom initialization method to PsiCash
              [[PsiCashClient sharedInstance] scheduleRefreshState];
              [[AdManager sharedInstance] initializeAdManager];
          }]
          subscribeError:^(NSError *error) {
              [weakSelf.compoundDisposable removeDisposable:startDisposable];
          }
          completed:^{
              [weakSelf.compoundDisposable removeDisposable:startDisposable];
          }];

        [self.compoundDisposable addDisposable:startDisposable];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    LOG_DEBUG();
    [super viewDidAppear:animated];
    // Available regions may have changed in the background
    // TODO: maybe have availableServerRegions listen to a global signal?
    [availableServerRegions sync];
    [regionSelectionButton update];
    
    if (self.openSettingImmediatelyOnViewDidAppear) {
        [self openSettingsMenu];
        self.openSettingImmediatelyOnViewDidAppear = FALSE;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    bottomBarGradient.frame = bottomBar.bounds;
}

- (void)viewWillAppear:(BOOL)animated {
    LOG_DEBUG();
    [super viewWillAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
    LOG_DEBUG();
    [super viewWillDisappear:animated];
}

- (void)viewDidDisappear:(BOOL)animated {
    LOG_DEBUG();
    [super viewDidDisappear:animated];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

// Reload when rotate
- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {

    [self setStartButtonSizeConstraints:size];
    
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

#pragma mark - Public properties

- (RACSignal<RACUnit *> *)activeStateLoadingSignal {

    // adsLoadingSignal emits a value when untunnelled interstitial ad has loaded or
    // when MaxAdLoadingTime has passed.
    // If the device in not in untunneled state, this signal makes an emission and
    // then completes immediately, without checking the untunneled interstitial status.
    RACSignal *adsLoadingSignal = [[[VPNManager sharedInstance].lastTunnelStatus
      flattenMap:^RACSignal *(NSNumber *statusObject) {

          VPNStatus s = (VPNStatus) [statusObject integerValue];
          BOOL needAdConsent = [MoPub sharedInstance].shouldShowConsentDialog;

          if (!needAdConsent && (s == VPNStatusDisconnected || s == VPNStatusInvalid)) {

              // Device is untunneled and ad consent is given or not needed,
              // we therefore wait for the ad to load.
              return [[[[AdManager sharedInstance].untunneledInterstitialCanPresent
                filter:^BOOL(NSNumber *adIsReady) {
                    return [adIsReady boolValue];
                }]
                merge:[RACSignal timer:MaxAdLoadingTime]]
                take:1];

          } else {
              // Device in _not_ untunneled or we need to show the Ad consent modal screen,
              // wo we will emit RACUnit immediately since no ads will be loaded here.
              return [RACSignal return:RACUnit.defaultUnit];
          }
      }]
      take:1];

    // subscriptionLoadingSignal emits a value when the user subscription status becomes known.
    RACSignal *subscriptionLoadingSignal = [[[AppDelegate sharedAppDelegate].subscriptionStatus
      filter:^BOOL(NSNumber *value) {
          UserSubscriptionStatus s = (UserSubscriptionStatus) [value integerValue];
          return (s != UserSubscriptionUnknown);
      }]
      take:1];

    // Returned signal emits RACUnit and completes immediately after all loading operations
    // are done.
    return [subscriptionLoadingSignal flattenMap:^RACSignal *(NSNumber *value) {
        BOOL subscribed = ([value integerValue] == UserSubscriptionActive);

        if (subscribed) {
            // User is subscribed, dismiss the loading screen immediately.
            return [RACSignal return:RACUnit.defaultUnit];
        } else {
            // User is not subscribed, wait for the adsLoadingSignal.
            return [adsLoadingSignal mapReplace:RACUnit.defaultUnit];
        }
    }];
}

// Emits one of the `Command_` strings.
- (RACSignal<NSString *> *)startOrStopVPNSignalWithAd:(BOOL)showAd {
    MainViewController *__weak weakSelf = self;

    return [[[[self.vpnManager isVPNActive]
      flattenMap:^RACSignal<NSString *> *(RACTwoTuple<NSNumber *, NSNumber *> *value) {
          BOOL vpnActive = [value.first boolValue];
          BOOL isZombie = (VPNStatusZombie == (VPNStatus)[value.second integerValue]);

          // Emits command to stop VPN if it has already started or is in zombie mode.
          // Otherwise, it checks for internet connectivity and emits
          // one of CommandNoInternetAlert or CommandStartTunnel.
          if (vpnActive || isZombie) {
              return [RACSignal return:CommandStopVPN];

          } else {
              // Alerts the user if there is no internet connection.
              Reachability *reachability = [Reachability reachabilityForInternetConnection];
              if ([reachability currentReachabilityStatus] == NotReachable) {
                  return [RACSignal return:CommandNoInternetAlert];

              } else {

                  // Returned signal checks whether or not VPN configuration is already installed.
                  // Skips presenting ads if the VPN configuration is not installed, or
                  // we're asked to not show ads.
                  return [[weakSelf.vpnManager vpnConfigurationInstalled]
                    flattenMap:^RACSignal *(NSNumber *value) {
                        BOOL vpnInstalled = [value boolValue];

                        if (!vpnInstalled || !showAd) {
                            return [RACSignal return:CommandStartTunnel];
                        } else {
                            // Start tunnel after ad presentation signal completes.
                            // We always want to start the tunnel after the presentation signal
                            // is completed, no matter if it presented an ad or it failed.
                            return [[weakSelf.adManager
                              presentInterstitialOnViewController:weakSelf]
                              then:^RACSignal * {
                                  return [RACSignal return:CommandStartTunnel];
                              }];
                        }
                    }];
              }
          }

      }]
      doNext:^(NSString *command) {
          dispatch_async_main(^{
              if ([CommandStartTunnel isEqualToString:command]) {
                  [weakSelf.vpnManager startTunnel];

              } else if ([CommandStopVPN isEqualToString:command]) {
                  [weakSelf.vpnManager stopVPN];

              } else if ([CommandNoInternetAlert isEqualToString:command]) {
                  [[AppDelegate sharedAppDelegate] displayAlertNoInternet:nil];
              }
          });
      }]
      deliverOnMainThread];
}

#pragma mark - UI callbacks

- (void)onStartStopTap:(UIButton *)sender {
    MainViewController *__weak weakSelf = self;

    __block RACDisposable *disposable = [[self startOrStopVPNSignalWithAd:TRUE]
      subscribeError:^(NSError *error) {
        [weakSelf.compoundDisposable removeDisposable:disposable];
      }
      completed:^{
        [weakSelf.compoundDisposable removeDisposable:disposable];
      }];

    [self.compoundDisposable addDisposable:disposable];
}

- (void)onSettingsButtonTap:(UIButton *)sender {
    [self openSettingsMenu];
}

- (void)onRegionSelectionButtonTap:(UIButton *)sender {
    NSString *selectedRegionCodeSnapshot = [[RegionAdapter sharedInstance] getSelectedRegion].code;

    SkyRegionSelectionViewController *regionViewController =
      [[SkyRegionSelectionViewController alloc] init];

    MainViewController *__weak weakSelf = self;

    regionViewController.selectionHandler =
      ^(NSUInteger selectedIndex, id selectedItem, PickerViewController *viewController) {
          MainViewController *__strong strongSelf = weakSelf;
          if (strongSelf != nil) {

              Region *selectedRegion = (Region *)selectedItem;

              [[RegionAdapter sharedInstance] setSelectedRegion:selectedRegion.code];

              if (![NSString stringsBothEqualOrNil:selectedRegion.code b:selectedRegionCodeSnapshot]) {
                  [strongSelf persistSelectedRegion];
                  [strongSelf->regionSelectionButton update];
                  [weakSelf.vpnManager restartVPNIfActive];
              }

              [viewController dismissViewControllerAnimated:TRUE completion:nil];
          }
      };

    UINavigationController *navController = [[UINavigationController alloc]
      initWithRootViewController:regionViewController];
    [self presentViewController:navController animated:YES completion:nil];
}

- (void)onSubscriptionTap {
    [self openIAPViewController];
}

#if DEBUG
- (void)onVersionLabelTap:(UIButton *)sender {
    DebugViewController *viewController = [[DebugViewController alloc] initWithCoder:nil];
    [self presentViewController:viewController animated:YES completion:nil];
}
#endif

# pragma mark - UI helper functions

- (NSString *)getVPNStatusDescription:(VPNStatus)status {
    switch(status) {
        case VPNStatusDisconnected: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_DISCONNECTED", nil, [NSBundle mainBundle], @"Disconnected", @"Status when the VPN is not connected to a Psiphon server, not trying to connect, and not in an error state");
        case VPNStatusInvalid: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_INVALID", nil, [NSBundle mainBundle], @"Disconnected", @"Status when the VPN is in an invalid state. For example, if the user doesn't give permission for the VPN configuration to be installed, and therefore the Psiphon VPN can't even try to connect.");
        case VPNStatusConnected: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_CONNECTED", nil, [NSBundle mainBundle], @"Connected", @"Status when the VPN is connected to a Psiphon server");
        case VPNStatusConnecting: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_CONNECTING", nil, [NSBundle mainBundle], @"Connecting", @"Status when the VPN is connecting; that is, trying to connect to a Psiphon server");
        case VPNStatusDisconnecting: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_DISCONNECTING", nil, [NSBundle mainBundle], @"Disconnecting", @"Status when the VPN is disconnecting. Sometimes going from connected to disconnected can take some time, and this is that state.");
        case VPNStatusReasserting: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_RECONNECTING", nil, [NSBundle mainBundle], @"Reconnecting", @"Status when the VPN was connected to a Psiphon server, got disconnected unexpectedly, and is currently trying to reconnect");
        case VPNStatusRestarting: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_RESTARTING", nil, [NSBundle mainBundle], @"Restarting", @"Status when the VPN is restarting.");
        case VPNStatusZombie: return @"...";
    }
    [PsiFeedbackLogger error:@"MainViewController unhandled VPNStatus (%ld)", status];
    return nil;
}

- (void)setupSettingsButton {
    UIImage *gearTemplate = [UIImage imageNamed:@"GearDark"];
    settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [settingsButton setImage:gearTemplate forState:UIControlStateNormal];

    // Setup autolayout
    CGFloat buttonTouchAreaSize = 80.f;
    [settingsButton.topAnchor constraintEqualToAnchor:psiCashView.topAnchor constant:-(buttonTouchAreaSize - gearTemplate.size.height)/2].active = YES;
    [settingsButton.trailingAnchor constraintEqualToAnchor:psiCashView.trailingAnchor constant:(buttonTouchAreaSize/2 - gearTemplate.size.width/2)].active = YES;
    [settingsButton.widthAnchor constraintEqualToConstant:buttonTouchAreaSize].active = YES;
    [settingsButton.heightAnchor constraintEqualToAnchor:settingsButton.widthAnchor].active = YES;

    [settingsButton addTarget:self action:@selector(onSettingsButtonTap:) forControlEvents:UIControlEventTouchUpInside];
}

- (void)updateUIConnectionState:(VPNStatus)s {
    [self positionClouds:s];

    [startAndStopButton setHighlighted:FALSE];
    
    if ([VPNManager mapIsVPNActive:s] && s != VPNStatusConnected) {
        [startAndStopButton setConnecting];
    }
    else if (s == VPNStatusConnected) {
        [startAndStopButton setConnected];
    }
    else {
        [startAndStopButton setDisconnected];
    }
    
    [self setStatusLabelText:[self getVPNStatusDescription:s]];
}

// Add all views at the same time so there are no crashes while
// adding and activating autolayout constraints.
- (void)addViews {
    UIImage *cloud = [UIImage imageNamed:@"cloud"];
    cloudMiddleLeft = [[UIImageView alloc] initWithImage:cloud];
    cloudMiddleRight = [[UIImageView alloc] initWithImage:cloud];
    cloudTopRight = [[UIImageView alloc] initWithImage:cloud];
    cloudBottomRight = [[UIImageView alloc] initWithImage:cloud];
    versionLabel = [[UIButton alloc] init];
    settingsButton = [[UIButton alloc] init];
    psiphonSmallLogo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"PsiphonSmallLogoWhite"]];
    psiphonLargeLogo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"PsiphonLogoWhite"]];
    psiCashView = [[PsiCashView alloc] initWithAutoLayout];
    startAndStopButton = [VPNStartAndStopButton buttonWithType:UIButtonTypeCustom];
    statusLabel = [[UILabel alloc] init];
    regionSelectionButton = [[RegionSelectionButton alloc] init];
    bottomBar = [[UIView alloc] init];
    subscriptionsBar = [[SubscriptionsBar alloc] init];

    // NOTE: some views overlap so the order they are added
    //       is important for user interaction.
    [self.view addSubview:cloudMiddleLeft];
    [self.view addSubview:cloudMiddleRight];
    [self.view addSubview:cloudTopRight];
    [self.view addSubview:cloudBottomRight];
    [self.view addSubview:psiphonSmallLogo];
    [self.view addSubview:psiphonLargeLogo];
    [self.view addSubview:psiCashView];
    [self.view addSubview:versionLabel];
    [self.view addSubview:settingsButton];
    [self.view addSubview:startAndStopButton];
    [self.view addSubview:statusLabel];
    [self.view addSubview:regionSelectionButton];
    [self.view addSubview:bottomBar];
    [self.view addSubview:subscriptionsBar];
}

- (void)setupClouds {

    UIImage *cloud = [UIImage imageNamed:@"cloud"];

    cloudMiddleLeft.translatesAutoresizingMaskIntoConstraints = NO;
    [cloudMiddleLeft.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor].active = YES;
    [cloudMiddleLeft.heightAnchor constraintEqualToConstant:cloud.size.height].active = YES;
    [cloudMiddleLeft.widthAnchor constraintEqualToConstant:cloud.size.width].active = YES;

    cloudMiddleRight.translatesAutoresizingMaskIntoConstraints = NO;
    [cloudMiddleRight.centerYAnchor constraintEqualToAnchor:cloudMiddleLeft.centerYAnchor].active = YES;
    [cloudMiddleRight.heightAnchor constraintEqualToConstant:cloud.size.height].active = YES;
    [cloudMiddleRight.widthAnchor constraintEqualToConstant:cloud.size.width].active = YES;

    cloudTopRight.translatesAutoresizingMaskIntoConstraints = NO;
    [cloudTopRight.topAnchor constraintEqualToAnchor:psiCashView.bottomAnchor constant:-20].active = YES;
    [cloudTopRight.heightAnchor constraintEqualToConstant:cloud.size.height].active = YES;
    [cloudTopRight.widthAnchor constraintEqualToConstant:cloud.size.width].active = YES;

    cloudBottomRight.translatesAutoresizingMaskIntoConstraints = NO;
    [cloudBottomRight.centerYAnchor constraintEqualToAnchor:regionSelectionButton.topAnchor constant:-24].active = YES;
    [cloudBottomRight.heightAnchor constraintEqualToConstant:cloud.size.height].active = YES;
    [cloudBottomRight.widthAnchor constraintEqualToConstant:cloud.size.width].active = YES;

    // Default horizontal positioning for clouds
    cloudMiddleLeftHorizontalConstraint = [cloudMiddleLeft.centerXAnchor constraintEqualToAnchor:self.view.leftAnchor constant:0];
    cloudMiddleRightHorizontalConstraint = [cloudMiddleRight.centerXAnchor constraintEqualToAnchor:self.view.rightAnchor constant:0]; // hide at first
    cloudTopRightHorizontalConstraint = [cloudTopRight.centerXAnchor constraintEqualToAnchor:self.view.rightAnchor constant:0];
    cloudBottomRightHorizontalConstraint = [cloudBottomRight.centerXAnchor constraintEqualToAnchor:self.view.rightAnchor constant:0];

    cloudMiddleLeftHorizontalConstraint.active = YES;
    cloudMiddleRightHorizontalConstraint.active = YES;
    cloudTopRightHorizontalConstraint.active = YES;
    cloudBottomRightHorizontalConstraint.active = YES;
}

- (void)positionClouds:(VPNStatus)s {

    // DEBUG: use to debug animations in slow motion (e.g. 20)
    CGFloat animationTimeStretchFactor = 1;

    static VPNStatus previousState = VPNStatusInvalid;

    CGFloat cloudWidth = [UIImage imageNamed:@"cloud"].size.width;

    // All clouds are centered on their respective side.
    // Use these variables to make slight adjustments to
    // each cloud's position.
    CGFloat cloudMiddleLeftOffset = 0;
    CGFloat cloudTopRightOffset = 0;
    CGFloat cloudBottomRightOffset = 15;

    // Remove all on-going cloud animations
    void (^removeAllCloudAnimations)(void) = ^void(void) {
        [cloudMiddleLeft.layer removeAllAnimations];
        [cloudMiddleRight.layer removeAllAnimations];
        [cloudTopRight.layer removeAllAnimations];
        [cloudBottomRight.layer removeAllAnimations];
    };

    // Position clouds in their default positions
    void (^disconnectedAndConnectedLayout)(void) = ^void(void) {
        cloudMiddleLeftHorizontalConstraint.constant = cloudMiddleLeftOffset;
        cloudMiddleRightHorizontalConstraint.constant = cloudWidth/2; // hidden
        cloudTopRightHorizontalConstraint.constant = cloudTopRightOffset;
        cloudBottomRightHorizontalConstraint.constant = cloudBottomRightOffset;
        [self.view layoutIfNeeded];
    };

    if ([VPNManager mapIsVPNActive:s] && s != VPNStatusConnected
        && s != VPNStatusRestarting) {
        // Connecting

        CGFloat cloudMiddleLeftHorizontalTranslation = -cloudWidth; // hidden
        CGFloat cloudMiddleRightHorizontalTranslation = -1.f/6 * cloudWidth + cloudMiddleLeftOffset;
        CGFloat cloudTopRightHorizontalTranslation = -3.f/4 * self.view.frame.size.width + cloudTopRightOffset;
        CGFloat cloudBottomRightHorizontalTranslation = -3.f/4 * self.view.frame.size.width + cloudBottomRightOffset;

        CGFloat maxTranslation = MAX(ABS(cloudMiddleLeftHorizontalTranslation), ABS(cloudMiddleRightHorizontalTranslation));
        maxTranslation = MAX(maxTranslation, MAX(ABS(cloudTopRightHorizontalTranslation),ABS(cloudBottomRightHorizontalTranslation)));

        void (^connectingLayout)(void) = ^void(void) {
            cloudMiddleLeftHorizontalConstraint.constant = cloudMiddleLeftHorizontalTranslation;
            cloudMiddleRightHorizontalConstraint.constant = cloudMiddleRightHorizontalTranslation;
            cloudTopRightHorizontalConstraint.constant = cloudTopRightHorizontalTranslation;
            cloudBottomRightHorizontalConstraint.constant = cloudBottomRightHorizontalTranslation;
            [self.view layoutIfNeeded];
        };

        cloudMiddleRightHorizontalConstraint.constant = maxTranslation - cloudWidth/2;
        [self.view layoutIfNeeded];

        if (!([VPNManager mapIsVPNActive:previousState]
              && previousState != VPNStatusConnected)
              && previousState != VPNStatusInvalid /* don't animate if the app was just opened */ ) {

            removeAllCloudAnimations();

            [UIView animateWithDuration:0.5 * animationTimeStretchFactor delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
                connectingLayout();
            } completion:nil];
        } else {
            connectingLayout();
        }
    }
    else if (s == VPNStatusConnected) {

        if (previousState != VPNStatusConnected
            && previousState != VPNStatusInvalid /* don't animate if the app was just opened */ ) {

            // Connected

            removeAllCloudAnimations();

            [UIView animateWithDuration:0.25 * animationTimeStretchFactor delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{

                cloudMiddleLeftHorizontalConstraint.constant = -cloudWidth; // hidden
                cloudMiddleRightHorizontalConstraint.constant = cloudWidth/2 + cloudMiddleLeftOffset;
                cloudTopRightHorizontalConstraint.constant = -self.view.frame.size.width - cloudWidth/2 + cloudTopRightOffset;
                cloudBottomRightHorizontalConstraint.constant = -self.view.frame.size.width - cloudWidth/2 + cloudBottomRightOffset;
                [self.view layoutIfNeeded];

            } completion:^(BOOL finished) {

                if (finished) {
                    // We want all the clouds to animate at the same speed so we put them all at the
                    // same distance from their final point.
                    CGFloat maxOffset = MAX(MAX(ABS(cloudMiddleLeftOffset), ABS(cloudTopRightOffset)), ABS(cloudBottomRightOffset));
                    cloudMiddleLeftHorizontalConstraint.constant = -cloudWidth/2 - (maxOffset + cloudMiddleLeftOffset);
                    cloudMiddleRightHorizontalConstraint.constant = cloudWidth/2 - (maxOffset + cloudMiddleLeftOffset);
                    cloudTopRightHorizontalConstraint.constant = cloudWidth/2 + (maxOffset + cloudTopRightOffset);
                    cloudBottomRightHorizontalConstraint.constant = cloudWidth/2 + (maxOffset + cloudBottomRightOffset);
                    [self.view layoutIfNeeded];

                    [UIView animateWithDuration:0.25 * animationTimeStretchFactor delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                        disconnectedAndConnectedLayout();
                    } completion:nil];
                }
            }];
        } else {
            disconnectedAndConnectedLayout();
        }
    }
    else {
        // Disconnected

        removeAllCloudAnimations();

        disconnectedAndConnectedLayout();
    }

    previousState = s;
}

- (void)setupStartAndStopButton {
    startAndStopButton.translatesAutoresizingMaskIntoConstraints = NO;
    [startAndStopButton addTarget:self action:@selector(onStartStopTap:) forControlEvents:UIControlEventTouchUpInside];
    
    // Setup autolayout
    [startAndStopButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor].active = YES;
    [startAndStopButton.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:05].active = YES;

    [self setStartButtonSizeConstraints:self.view.bounds.size];
}

- (void)setStartButtonSizeConstraints:(CGSize)size {
    if (startButtonWidth) {
        startButtonWidth.active = NO;
    }

    if (startButtonHeight) {
        startButtonHeight.active = NO;
    }

    CGFloat startButtonMaxSize = 200;
    CGFloat startButtonSize = MIN(MIN(size.width, size.height)*0.388, startButtonMaxSize);
    startButtonWidth = [startAndStopButton.widthAnchor constraintEqualToConstant:startButtonSize];
    startButtonHeight = [startAndStopButton.heightAnchor constraintEqualToAnchor:startAndStopButton.widthAnchor];

    startButtonWidth.active = YES;
    startButtonHeight.active = YES;
}

- (void)setupStatusLabel {
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statusLabel.adjustsFontSizeToFitWidth = YES;
    [self setStatusLabelText:[self getVPNStatusDescription:VPNStatusInvalid]];
    statusLabel.textAlignment = NSTextAlignmentCenter;
    statusLabel.textColor = UIColor.blueGreyColor;
    statusLabel.font = [UIFont avenirNextBold:14.5];
    
    // Setup autolayout
    CGFloat labelHeight = [statusLabel getLabelHeight];
    [statusLabel.heightAnchor constraintEqualToConstant:labelHeight].active = YES;
    [statusLabel.topAnchor constraintEqualToAnchor:startAndStopButton.bottomAnchor constant:20].active = YES;
    [statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor].active = YES;
}

- (void)setStatusLabelText:(NSString*)s {
    NSString *upperCased = [s localizedUppercaseString];
    NSMutableAttributedString *mutableStr = [[NSMutableAttributedString alloc]
      initWithString:upperCased];

    [mutableStr addAttribute:NSKernAttributeName
                       value:@1.1
                       range:NSMakeRange(0, mutableStr.length)];
    statusLabel.attributedText = mutableStr;
}

- (void)setupBottomBar {
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    bottomBar.backgroundColor = [UIColor clearColor];

    UITapGestureRecognizer *tapRecognizer = [[UITapGestureRecognizer alloc]
                                             initWithTarget:self action:@selector(onSubscriptionTap)];
    tapRecognizer.numberOfTapsRequired = 1;
    [bottomBar addGestureRecognizer:tapRecognizer];
    
    // Setup autolayout
    [NSLayoutConstraint activateConstraints:@[
      [bottomBar.topAnchor constraintEqualToAnchor:subscriptionsBar.topAnchor],
      [bottomBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
      [bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
      [bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];

    bottomBarGradient = [CAGradientLayer layer];
    bottomBarGradient.frame = bottomBar.bounds; // frame reset in viewDidLayoutSubviews
    bottomBarGradient.colors = @[(id)UIColor.lightRoyalBlueTwo.CGColor, (id)UIColor.lightishBlue.CGColor];

    [bottomBar.layer insertSublayer:bottomBarGradient atIndex:0];
}

- (void)setupRegionSelectionButton {
    regionSelectionButton.translatesAutoresizingMaskIntoConstraints = NO;
    
    CGFloat buttonHeight = 58;
    [regionSelectionButton addTarget:self action:@selector(onRegionSelectionButtonTap:) forControlEvents:UIControlEventTouchUpInside];

    // Set button height
    [regionSelectionButton.heightAnchor constraintEqualToConstant:buttonHeight].active = YES;

    [regionSelectionButton update];

    // Add constraints
    NSLayoutConstraint *idealBottomSpacing = [regionSelectionButton.bottomAnchor constraintEqualToAnchor:bottomBar.topAnchor constant:-31.f];
    [idealBottomSpacing setPriority:999];
    idealBottomSpacing.active = YES;
    [regionSelectionButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor].active = YES;
    [regionSelectionButton.widthAnchor constraintEqualToAnchor:bottomBar.widthAnchor multiplier:0.9f].active = YES;
}

- (void)setupSmallPsiphonLogoAndVersionLabel {

    psiphonSmallLogo.translatesAutoresizingMaskIntoConstraints = FALSE;
    psiphonSmallLogo.userInteractionEnabled = FALSE;

    // Setup autolayout
    [NSLayoutConstraint activateConstraints:@[
      [psiphonSmallLogo.leadingAnchor constraintEqualToAnchor:psiCashView.leadingAnchor],

      [psiphonSmallLogo.trailingAnchor
        constraintLessThanOrEqualToAnchor:psiCashView.balance.leadingAnchor
                                 constant:-2],

      [psiphonSmallLogo.topAnchor constraintEqualToAnchor:psiCashView.topAnchor]
    ]];


    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [versionLabel setTitle:[NSString stringWithFormat:@"v%@",[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]]
                  forState:UIControlStateNormal];
    [versionLabel setTitleColor:UIColor.nepalGreyBlueColor forState:UIControlStateNormal];
    versionLabel.titleLabel.adjustsFontSizeToFitWidth = YES;
    versionLabel.titleLabel.font = [UIFont avenirNextBold:10.5f];
    versionLabel.userInteractionEnabled = FALSE;
    versionLabel.contentEdgeInsets = UIEdgeInsetsMake(10.f, 10.f, 10.f, 10.f);

#if DEBUG
    versionLabel.userInteractionEnabled = TRUE;
    [versionLabel addTarget:self
                     action:@selector(onVersionLabelTap:)
           forControlEvents:UIControlEventTouchUpInside];
#endif

    // Setup autolayout
    [NSLayoutConstraint activateConstraints:@[
      [versionLabel.leadingAnchor constraintEqualToAnchor:psiphonSmallLogo.leadingAnchor constant:-10.f],
      [versionLabel.topAnchor constraintEqualToAnchor:psiphonSmallLogo.bottomAnchor constant:-10.f]
    ]];
}

- (void)setupAddSubscriptionsBar {
    [subscriptionsBar addTarget:self
                         action:@selector(onSubscriptionTap)
               forControlEvents:UIControlEventTouchUpInside];

    // Setup autolayout
    subscriptionsBar.translatesAutoresizingMaskIntoConstraints = FALSE;

    [NSLayoutConstraint activateConstraints:@[
      [subscriptionsBar.centerXAnchor constraintEqualToAnchor:bottomBar.centerXAnchor],
      [subscriptionsBar.centerYAnchor constraintEqualToAnchor:bottomBar.safeCenterYAnchor],
      [subscriptionsBar.widthAnchor constraintEqualToAnchor:self.view.widthAnchor],
      [subscriptionsBar.heightAnchor constraintEqualToAnchor:self.view.safeHeightAnchor
                                                  multiplier:0.11]
    ]];

}

#pragma mark - FeedbackViewControllerDelegate methods and helpers

- (void)userSubmittedFeedback:(NSUInteger)selectedThumbIndex
                     comments:(NSString *)comments
                        email:(NSString *)email
            uploadDiagnostics:(BOOL)uploadDiagnostics {

    [feedbackManager userSubmittedFeedback:selectedThumbIndex
                                  comments:comments
                                     email:email
                         uploadDiagnostics:uploadDiagnostics];
}

- (void)userPressedURL:(NSURL *)URL {
    [[UIApplication sharedApplication] openURL:URL options:@{} completionHandler:nil];
}

#pragma mark - PsiphonSettingsViewControllerDelegate methods and helpers

- (void)notifyPsiphonConnectionState {
    // Unused
}

- (void)reloadAndOpenSettings {
    if (appSettingsViewController != nil) {
        [appSettingsViewController dismissViewControllerAnimated:NO completion:^{
            [[RegionAdapter sharedInstance] reloadTitlesForNewLocalization];
            [[AppDelegate sharedAppDelegate] reloadMainViewControllerAndImmediatelyOpenSettings];
        }];
    }
}

- (void)settingsWillDismissWithForceReconnect:(BOOL)forceReconnect {
    if (forceReconnect) {
        [self persistSettingsToSharedUserDefaults];
        [self.vpnManager restartVPNIfActive];
    }
}

- (void)persistSettingsToSharedUserDefaults {
    [self persistDisableTimeouts];
    [self persistSelectedRegion];
    [self persistUpstreamProxySettings];
}

- (void)persistDisableTimeouts {
    NSUserDefaults *containerUserDefaults = [NSUserDefaults standardUserDefaults];
    NSUserDefaults *sharedUserDefaults = [[NSUserDefaults alloc] initWithSuiteName:APP_GROUP_IDENTIFIER];
    [sharedUserDefaults setObject:@([containerUserDefaults boolForKey:kDisableTimeouts]) forKey:kDisableTimeouts];
}

- (void)persistSelectedRegion {
    [[PsiphonConfigUserDefaults sharedInstance] setEgressRegion:[RegionAdapter.sharedInstance getSelectedRegion].code];
}

- (void)persistUpstreamProxySettings {
    NSUserDefaults *userDefaults = [[NSUserDefaults alloc] initWithSuiteName:APP_GROUP_IDENTIFIER];
    NSString *upstreamProxyUrl = [[UpstreamProxySettings sharedInstance] getUpstreamProxyUrl];
    [userDefaults setObject:upstreamProxyUrl forKey:PSIPHON_CONFIG_UPSTREAM_PROXY_URL];
    NSDictionary *upstreamProxyCustomHeaders = [[UpstreamProxySettings sharedInstance] getUpstreamProxyCustomHeaders];
    [userDefaults setObject:upstreamProxyCustomHeaders forKey:PSIPHON_CONFIG_UPSTREAM_PROXY_CUSTOM_HEADERS];
}

- (BOOL)shouldEnableSettingsLinks {
    return YES;
}

#pragma mark - Psiphon Settings

- (void)notice:(NSString *)noticeJSON {
    NSLog(@"Got notice %@", noticeJSON);
}

- (void)openSettingsMenu {
    appSettingsViewController = [[SettingsViewController alloc] init];
    appSettingsViewController.delegate = appSettingsViewController;
    appSettingsViewController.showCreditsFooter = NO;
    appSettingsViewController.showDoneButton = YES;
    appSettingsViewController.neverShowPrivacySettings = YES;
    appSettingsViewController.settingsDelegate = self;
    appSettingsViewController.preferencesSnapshot = [[[NSUserDefaults standardUserDefaults] dictionaryRepresentation] copy];

    UINavigationController *navController = [[UINavigationController alloc]
      initWithRootViewController:appSettingsViewController];
    [self presentViewController:navController animated:YES completion:nil];
}

#pragma mark - Subscription

- (void)openIAPViewController {
    IAPViewController *iapViewController = [[IAPViewController alloc] init];
    iapViewController.openedFromSettings = NO;
    UINavigationController *navController = [[UINavigationController alloc]
      initWithRootViewController:iapViewController];
    [self presentViewController:navController animated:YES completion:nil];
}

#pragma mark - PsiCash

#pragma mark - PsiCash UI callbacks

/**
 * Buy max num hours of Speed Boost that the user can afford if possible
 */
- (void)instantMaxSpeedBoostPurchase {
    if (![[psiCashOnboardingCompleted first] boolValue]) {
        PsiCashOnboardingViewController *onboarding = [[PsiCashOnboardingViewController alloc] init];
        onboarding.delegate = self;
        [self presentViewController:onboarding animated:NO completion:nil];
        return;
    }

    MainViewController *__weak weakSelf = self;

    // Checks the latest tunnel status before going ahead with the purchase request.
     __block RACDisposable *disposable = [[[VPNManager sharedInstance].lastTunnelStatus
       take:1]
       subscribeNext:^(NSNumber *value) {
           VPNStatus s = (VPNStatus) [value integerValue];

           if (s == VPNStatusConnected || s == VPNStatusDisconnected || s == VPNStatusInvalid) {
               // Device is either tunneled or untunneled, we can go ahead with the purchase request.
               PsiCashSpeedBoostProductSKU *purchase = [model maxSpeedBoostPurchaseEarned];

               if (![model hasPendingPurchase] && ![model hasActiveSpeedBoostPurchase] && purchase != nil) {
                   [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
                   [PsiCashClient.sharedInstance purchaseSpeedBoostProduct:purchase];
               } else {
                   [weakSelf showPsiCashAlertView];
               }
           } else {
               // Device is in a connecting or disconnecting state, we shouldn't do any purchase requests.
               // Informs the user through an alert.
               NSString *alertBody = NSLocalizedStringWithDefaultValue(@"PSICASH_CONNECTED_OR_DISCONNECTED",
                 nil,
                 [NSBundle mainBundle],
                 @"Speed Boost purchase unavailable while Psiphon is connecting.",
                 @"Alert message indicating to the user that they can't purchase Speed Boost while the app is connecting."
                 " Do not translate 'Psiphon'.");

               [UIAlertController presentSimpleAlertWithTitle:@"PsiCash"  // The word PsiCash is not translated.
                                                      message:alertBody
                                               preferredStyle:UIAlertControllerStyleAlert
                                                    okHandler:nil];
           }
       }
       completed:^{
           [weakSelf.compoundDisposable removeDisposable:disposable];
       }];

    [self.compoundDisposable addDisposable:disposable];
}

#pragma mark - PsiCash UI

- (void)setupPsiphonLogoView {
    psiphonLargeLogo.translatesAutoresizingMaskIntoConstraints = NO;

    psiphonLargeLogo.contentMode = UIViewContentModeScaleAspectFill;

    [psiphonLargeLogo.centerYAnchor constraintEqualToAnchor:versionLabel.centerYAnchor].active = YES;
    [psiphonLargeLogo.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor].active = YES;
}

- (void)setupPsiCashView {
    psiCashView.translatesAutoresizingMaskIntoConstraints = NO;

    UITapGestureRecognizer *psiCashViewTap = [[UITapGestureRecognizer alloc]
                                                  initWithTarget:self action:@selector(instantMaxSpeedBoostPurchase)];

    psiCashViewTap.numberOfTapsRequired = 1;
    [psiCashView.meter addGestureRecognizer:psiCashViewTap];

    [psiCashView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor].active = YES;
    [psiCashView.topAnchor constraintEqualToAnchor:self.topLayoutGuide.bottomAnchor constant:26].active = YES;

    CGFloat psiCashViewMaxWidth = 600;
    CGFloat psiCashViewToParentViewWidthRatio = 0.95;
    if (self.view.frame.size.width * psiCashViewToParentViewWidthRatio > psiCashViewMaxWidth) {
        [psiCashView.widthAnchor constraintEqualToConstant:psiCashViewMaxWidth].active = YES;
    } else {
        [psiCashView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor
                                              multiplier:psiCashViewToParentViewWidthRatio].active = YES;
    }
    psiCashViewHeight = [psiCashView.heightAnchor constraintEqualToConstant:146.9];
    psiCashViewHeight.active = YES;

    MainViewController *__weak weakSelf = self;


    RACDisposable *psiCashViewUpdates =
        [[[PsiCashClient.sharedInstance.clientModelSignal
        combineLatestWith:psiCashOnboardingCompleted]
        deliverOnMainThread]
        subscribeNext:^(RACTwoTuple<PsiCashClientModel *, NSNumber *> * _Nullable x) {

            PsiCashClientModel *newClientModel = [x first];
            newClientModel.onboarded = [[x second] boolValue];

            MainViewController *__strong strongSelf = weakSelf;

            if (strongSelf != nil) {
                BOOL stateChanged =    [strongSelf->model hasActiveSpeedBoostPurchase] ^
                                       [newClientModel hasActiveSpeedBoostPurchase]
                                    ||
                                       [strongSelf->model hasPendingPurchase] ^
                                       [newClientModel hasPendingPurchase];
                if (   strongSelf->model
                    && [strongSelf->model hasActiveSpeedBoostPurchase] == FALSE
                    && [newClientModel hasActiveSpeedBoostPurchase] == TRUE) {
                    // Speed Boost has activated
                    [[[UINotificationFeedbackGenerator alloc] init]
                     notificationOccurred:UINotificationFeedbackTypeSuccess];
                }

                NSComparisonResult balanceChange = [strongSelf->model.balance compare:newClientModel.balance];

                if (balanceChange != NSOrderedSame) {

                    [[[UINotificationFeedbackGenerator alloc] init]
                     notificationOccurred:UINotificationFeedbackTypeSuccess];

                    NSNumber *balanceChange = [NSNumber numberWithDouble:newClientModel.balance.doubleValue
                                              - strongSelf->model.balance.doubleValue];
                    [PsiCashView animateBalanceChangeOf:balanceChange
                                        withPsiCashView:strongSelf->psiCashView
                                           inParentView:strongSelf.view];
                }

                strongSelf->model = newClientModel;

                if (stateChanged && strongSelf->alertView != nil) {
                    [strongSelf showPsiCashAlertView];
                }

                [strongSelf->psiCashView bindWithModel:strongSelf->model];
            }
    }];

    [self.compoundDisposable addDisposable:psiCashViewUpdates];

    [self.compoundDisposable addDisposable:[[[AdManager sharedInstance].rewardedVideoCanPresent
      combineLatestWith:PsiCashClient.sharedInstance.clientModelSignal]
      subscribeNext:^(RACTwoTuple<NSNumber *, PsiCashClientModel *> *tuple) {
          MainViewController *__strong strongSelf = weakSelf;
          if (strongSelf != nil) {

              BOOL ready = [tuple.first boolValue];
              PsiCashClientModel *model = tuple.second;

              BOOL shouldEnable = ready && [model.authPackage hasEarnerToken];
              strongSelf->psiCashView.rewardedVideoButton.userInteractionEnabled = shouldEnable;
              strongSelf->psiCashView.rewardedVideoButton.enabled = shouldEnable;

#if DEBUG
              if ([AppInfo runningUITest]) {
                  // Fake the rewarded video bar enabled status for automated screenshots.
                  strongSelf->psiCashView.rewardedVideoButton.enabled = TRUE;
              }
#endif
          }
    }]];

    [psiCashView.rewardedVideoButton addTarget:self
                                        action:@selector(showRewardedVideo)
                              forControlEvents:UIControlEventTouchUpInside];

#if DEBUG
    if ([AppInfo runningUITest]) {
        [psiCashViewUpdates dispose];
        [self onboardingEnded];

        PsiCashSpeedBoostProductSKU *sku =
          [PsiCashSpeedBoostProductSKU skuWitDistinguisher:@"1h"
                                                 withHours:[NSNumber numberWithInteger:1]
                                                  andPrice:[NSNumber numberWithDouble:100e9]];

        PsiCashClientModel *m = [PsiCashClientModel
            clientModelWithAuthPackage:[[PsiCashAuthPackage alloc]
                                         initWithValidTokens:@[@"indicator", @"earner", @"spender"]]
                            andBalance:[NSNumber numberWithDouble:70e9]
                  andSpeedBoostProduct:[PsiCashSpeedBoostProduct productWithSKUs:@[sku]]
                   andPendingPurchases:nil
           andActiveSpeedBoostPurchase:nil
                     andRefreshPending:NO];

        [psiCashView bindWithModel:m];
    }
#endif
}

- (void)setPsiCashContentHidden:(BOOL)hidden {
    psiCashView.hidden = hidden;
    psiCashView.userInteractionEnabled = !hidden;

    // Show Psiphon large logo and hide Psiphon small logo when PsiCash is hidden.
    psiphonLargeLogo.hidden = !hidden;
    psiphonSmallLogo.hidden = hidden;
}

- (void)showRewardedVideo {

    MainViewController *__weak weakSelf = self;

    LOG_DEBUG(@"rewarded video started");
    [PsiFeedbackLogger infoWithType:RewardedVideoLogType message:@"started"];

    RACDisposable *__block disposable = [[[[self.adManager
        presentRewardedVideoOnViewController:self
                              withCustomData:[[PsiCashClient sharedInstance] rewardedVideoCustomData]]
        doNext:^(NSNumber *adPresentationEnum) {
            // Logs current AdPresentation enum value.
            AdPresentation ap = (AdPresentation) [adPresentationEnum integerValue];
            switch (ap) {
                case AdPresentationWillAppear:
                    LOG_DEBUG(@"rewarded video AdPresentationWillAppear");
                    break;
                case AdPresentationDidAppear:
                    LOG_DEBUG(@"rewarded video AdPresentationDidAppear");
                    break;
                case AdPresentationWillDisappear:
                    LOG_DEBUG(@"rewarded video AdPresentationWillDisappear");
                    break;
                case AdPresentationDidDisappear:
                    LOG_DEBUG(@"rewarded video AdPresentationDidDisappear");
                    break;
                case AdPresentationDidRewardUser:
                    LOG_DEBUG(@"rewarded video AdPresentationDidRewardUser");
                    break;
                case AdPresentationErrorCustomDataNotSet:
                    LOG_DEBUG(@"rewarded video AdPresentationErrorCustomDataNotSet");
                    [PsiFeedbackLogger errorWithType:RewardedVideoLogType
                                             message:@"AdPresentationErrorCustomDataNotSet"];
                    break;
                case AdPresentationErrorInappropriateState:
                    LOG_DEBUG(@"rewarded video AdPresentationErrorInappropriateState");
                    [PsiFeedbackLogger errorWithType:RewardedVideoLogType
                                             message:@"AdPresentationErrorInappropriateState"];
                    break;
                case AdPresentationErrorNoAdsLoaded:
                    LOG_DEBUG(@"rewarded video AdPresentationErrorNoAdsLoaded");
                    [PsiFeedbackLogger errorWithType:RewardedVideoLogType
                                             message:@"AdPresentationErrorNoAdsLoaded"];
                    break;
                case AdPresentationErrorFailedToPlay:
                    LOG_DEBUG(@"rewarded video AdPresentationErrorFailedToPlay");
                    [PsiFeedbackLogger errorWithType:RewardedVideoLogType
                                             message:@"AdPresentationErrorFailedToPlay"];
                    break;
            }
        }]
        scanWithStart:[RACTwoTuple pack:@(FALSE) :@(FALSE)]
               reduce:^RACTwoTuple<NSNumber *, NSNumber *> *(RACTwoTuple *running, NSNumber *adPresentationEnum) {

            // Scan operator's `running` value is a 2-tuple of booleans. First element represents when
            // AdPresentationDidRewardUser is emitted upstream, and the second element represents when
            // AdPresentationDidDisappear is emitted upstream.
            // Note that we don't want to make any assumptions about the order of these two events.
            if ([adPresentationEnum integerValue] == AdPresentationDidRewardUser) {
                return [RACTwoTuple pack:@(TRUE) :running.second];
            } else if ([adPresentationEnum integerValue] == AdPresentationDidDisappear) {
                return [RACTwoTuple pack:running.first :@(TRUE)];
            }
            return running;
        }]
        subscribeNext:^(RACTwoTuple<NSNumber *, NSNumber *> *tuple) {
            // Calls to update PsiCash balance after
            BOOL didReward = [tuple.first boolValue];
            BOOL didDisappear = [tuple.second boolValue];
            if (didReward && didDisappear) {
                [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
                [[PsiCashClient sharedInstance] pollForBalanceDeltaWithMaxRetries:30 andTimeBetweenRetries:1.0];
            }
        } error:^(NSError *error) {
            [PsiFeedbackLogger errorWithType:RewardedVideoLogType message:@"Error with rewarded video" object:error];
            [weakSelf.compoundDisposable removeDisposable:disposable];
        } completed:^{
            LOG_DEBUG(@"rewarded video completed");
            [PsiFeedbackLogger infoWithType:RewardedVideoLogType message:@"completed"];
            [weakSelf.compoundDisposable removeDisposable:disposable];
        }];

        [self.compoundDisposable addDisposable:disposable];
}

#pragma mark - PsiCashPurchaseAlertViewDelegate protocol

- (void)stateBecameStale {
    [alertView close];
    alertView = nil;
}

- (void)showPsiCashAlertView {
    if (alertView != nil) {
        [alertView close];
        alertView = nil;
    }

    if (![model hasAuthPackage] || ![model.authPackage hasSpenderToken]) {
        return;
    } else if ([model hasActiveSpeedBoostPurchase]) {
        alertView = [PsiCashPurchaseAlertView alreadySpeedBoostingAlert];
    } else  if ([model hasPendingPurchase]) {
        // (PsiCash 1.0): Do nothing
        //alertView = [PsiCashPurchaseAlertView pendingPurchaseAlert];
        return;
    } else {
        // Insufficient balance animation
        CABasicAnimation *animation =
        [CABasicAnimation animationWithKeyPath:@"position"];
        [animation setDuration:0.075];
        [animation setRepeatCount:3];
        [animation setAutoreverses:YES];
        [animation setFromValue:[NSValue valueWithCGPoint:
                                 CGPointMake([psiCashView center].x - 20.0f, [psiCashView center].y)]];
        [animation setToValue:[NSValue valueWithCGPoint:
                               CGPointMake([psiCashView center].x + 20.0f, [psiCashView center].y)]];
        [[psiCashView layer] addAnimation:animation forKey:@"position"];
        return;
    }

    alertView.controllerDelegate = self;
    [alertView bindWithModel:model];
    [alertView show];
}


#pragma mark - PsiCashOnboardingViewControllerDelegate protocol implementation

- (void)onboardingEnded {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:PsiCashHasBeenOnboardedBoolKey];
    [psiCashOnboardingCompleted sendNext:[NSNumber numberWithBool:YES]];
}

#pragma mark - RegionAdapterDelegate protocol implementation

- (void)selectedRegionDisappearedThenSwitchedToBestPerformance {
    MainViewController *__weak weakSelf = self;
    dispatch_async_main(^{
        MainViewController *__strong strongSelf = weakSelf;
        [strongSelf->regionSelectionButton update];
    });
    [self persistSelectedRegion];
}

@end
